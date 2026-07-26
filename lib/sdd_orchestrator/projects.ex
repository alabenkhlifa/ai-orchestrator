defmodule SddOrchestrator.Projects do
  @moduledoc """
  Projects context: the workspace-scoped project catalog, the short-lived
  onboarding-attempt lifecycle, and atomic project registration.

  Hosted attempts and projects are scoped through a personal profile to the
  common logical workspace root, so a catalog query, attempt lookup, or
  registration can never cross the ownership boundary. `register_project/3`
  creates a hosted project, its canonical repository connection, and its storage
  state in one transaction — or leaves no partial record — while device
  registration remains destination-owned by the worker transaction in Task 4.
  """
  import Ecto.Query

  alias Ecto.Multi
  alias SddOrchestrator.Accounts.PersonalWorkspace
  alias SddOrchestrator.Projects.{Project, ProjectOnboardingAttempt, RepositoryConnection}
  alias SddOrchestrator.ProjectStorage
  alias SddOrchestrator.ProjectStorage.{DeviceStorageReceipt, Hosted}
  alias SddOrchestrator.Repo

  # Abandoned onboarding attempts become unusable after this window and are
  # pruned by the retention job (approved development privacy contract).
  @attempt_ttl_seconds 24 * 60 * 60

  # Bounds the default-name suffix search and its concurrency retry so a pathologically
  # crowded workspace can never loop unbounded.
  @max_suffix_retries 50

  ## Catalog

  @doc "Lists the projects in a workspace, ordered by display name."
  @spec list_catalog(PersonalWorkspace.t()) :: [Project.t()]
  def list_catalog(%PersonalWorkspace{id: workspace_id}) do
    Repo.all(
      from p in Project,
        where: p.workspace_id == ^workspace_id,
        order_by: [asc: p.name, asc: p.id]
    )
  end

  @doc "Returns true when the workspace already owns at least one project."
  @spec has_projects?(PersonalWorkspace.t()) :: boolean()
  def has_projects?(%PersonalWorkspace{id: workspace_id}) do
    Repo.exists?(from p in Project, where: p.workspace_id == ^workspace_id)
  end

  @doc """
  Fetches one project by id, scoped to the workspace, with its repository
  connection and hosted storage preloaded. Returns nil for a missing, malformed,
  or cross-workspace id so a foreign project is never resolved.
  """
  @spec get_project(PersonalWorkspace.t(), String.t()) :: Project.t() | nil
  def get_project(%PersonalWorkspace{id: workspace_id}, project_id) when is_binary(project_id) do
    case Ecto.UUID.cast(project_id) do
      {:ok, uuid} ->
        Repo.one(
          from p in Project,
            where: p.id == ^uuid and p.workspace_id == ^workspace_id,
            preload: [:repository_connection, :hosted_storage]
        )

      :error ->
        nil
    end
  end

  ## Onboarding attempts

  @doc """
  Returns the workspace's current active onboarding attempt, starting a fresh one
  when none is in flight.

  "Active" means unconsumed and unexpired. Reusing the in-flight attempt keeps
  the flow resumable and makes entry idempotent under reconnects and repeated
  navigation, so a workspace never accumulates parallel live attempts.
  """
  @spec get_or_start_onboarding_attempt(PersonalWorkspace.t()) ::
          {:ok, ProjectOnboardingAttempt.t()} | {:error, Ecto.Changeset.t()}
  def get_or_start_onboarding_attempt(%PersonalWorkspace{id: workspace_id} = workspace) do
    case Repo.one(active_attempt_query(workspace_id)) do
      nil -> start_onboarding_attempt(workspace)
      %ProjectOnboardingAttempt{} = attempt -> {:ok, attempt}
    end
  end

  @doc "Starts a fresh onboarding attempt with an initial state and idempotency key."
  @spec start_onboarding_attempt(PersonalWorkspace.t()) ::
          {:ok, ProjectOnboardingAttempt.t()} | {:error, Ecto.Changeset.t()}
  def start_onboarding_attempt(%PersonalWorkspace{id: workspace_id}) do
    %ProjectOnboardingAttempt{}
    |> ProjectOnboardingAttempt.create_changeset(%{
      workspace_id: workspace_id,
      idempotency_key: Ecto.UUID.generate(),
      status: "started",
      expires_at: DateTime.add(now(), @attempt_ttl_seconds, :second)
    })
    |> Repo.insert()
  end

  @doc """
  Fetches an onboarding attempt by id, scoped to the workspace. Returns nil for a
  missing, malformed, or cross-workspace id so a foreign attempt is never
  resolved.
  """
  @spec get_onboarding_attempt(PersonalWorkspace.t(), String.t()) ::
          ProjectOnboardingAttempt.t() | nil
  def get_onboarding_attempt(%PersonalWorkspace{id: workspace_id}, attempt_id)
      when is_binary(attempt_id) do
    case Ecto.UUID.cast(attempt_id) do
      {:ok, uuid} ->
        Repo.one(
          from a in ProjectOnboardingAttempt,
            where: a.id == ^uuid and a.workspace_id == ^workspace_id
        )

      :error ->
        nil
    end
  end

  @doc """
  Records the confirmed repository selection on a workspace-scoped attempt.

  Only the approved repository metadata is stored (numeric id, owner, name,
  visibility, organization, url). Returns `{:error, :not_found}` for an unknown,
  malformed, or cross-workspace attempt so a foreign attempt is never written.
  The repository is stored as-selected; whether it is already linked is enforced
  by the registration transaction, not here.
  """
  @spec select_repository(PersonalWorkspace.t(), String.t(), map()) ::
          {:ok, ProjectOnboardingAttempt.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def select_repository(%PersonalWorkspace{} = workspace, attempt_id, repository)
      when is_binary(attempt_id) and is_map(repository) do
    update_attempt(workspace, attempt_id, fn attempt ->
      ProjectOnboardingAttempt.select_repository_changeset(attempt, selected_metadata(repository))
    end)
  end

  @doc """
  Records the explicitly chosen storage mode on a workspace-scoped attempt. Does
  not create a project. Returns `{:error, :not_found}` for a foreign attempt.
  """
  @spec select_storage_mode(PersonalWorkspace.t(), String.t(), String.t()) ::
          {:ok, ProjectOnboardingAttempt.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def select_storage_mode(%PersonalWorkspace{} = workspace, attempt_id, mode)
      when is_binary(attempt_id) and is_binary(mode) do
    update_attempt(workspace, attempt_id, fn attempt ->
      ProjectOnboardingAttempt.select_storage_changeset(attempt, mode)
    end)
  end

  @doc """
  Records a device-storage readiness receipt on a workspace-scoped attempt.

  This is the local-device handoff boundary: `specs/02-local-project-onboarding/`
  calls it after the user prepares on-device storage, so a later mount of the
  storage step sees device storage as available. It never selects a mode or
  creates a project. Returns `{:error, :not_found}` for a foreign attempt.
  """
  @spec record_device_receipt(PersonalWorkspace.t(), String.t(), DeviceStorageReceipt.t()) ::
          {:ok, ProjectOnboardingAttempt.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def record_device_receipt(
        %PersonalWorkspace{} = workspace,
        attempt_id,
        %DeviceStorageReceipt{} = receipt
      )
      when is_binary(attempt_id) do
    update_attempt(workspace, attempt_id, fn attempt ->
      ProjectOnboardingAttempt.device_setup_changeset(
        attempt,
        DeviceStorageReceipt.to_map(receipt)
      )
    end)
  end

  ## Registration and naming

  @doc """
  The default project display name for a repository, allocating the lowest
  available numeric suffix when the repository name is already used in the
  workspace.

  The repository name's display spelling and case are preserved; only the
  case-insensitive comparison key is used to detect a conflict. `example` with no
  conflict returns `example`; with `example` and `example-1` already present it
  returns `example-2`.
  """
  @spec default_project_name(PersonalWorkspace.t(), String.t()) :: String.t()
  def default_project_name(%PersonalWorkspace{} = workspace, base_name)
      when is_binary(base_name) do
    base = default_base(base_name)

    if name_available?(workspace, base),
      do: base,
      else: next_suffixed_name(workspace, base, 1)
  end

  @doc """
  Registers a project for a confirmed onboarding attempt: creates the project, its
  canonical repository connection, and its storage state in one transaction, then
  consumes the attempt.

  Options:

    * `:name` — the confirmed display name. Defaults to `default_project_name/2`
      for the selected repository.
    * `:allocate_suffix?` — when `true`, a workspace name collision re-allocates
      the next available default suffix and retries (the user accepted the
      suggested default). When `false` (the default), a collision returns an
      inline changeset error so an edited name is never silently changed.

  Returns `{:ok, project}` with the connection and storage preloaded, an idempotent
  `{:ok, project}` when the attempt was already consumed, `{:error, changeset}` for
  invalid or conflicting names, `{:error, {:repository_already_linked, project}}`
  when the repository already links an existing project in the workspace, or
  `{:error, reason}` for a storage or transaction failure. No partial project or
  connection is left on any failure.
  """
  @spec register_project(PersonalWorkspace.t(), ProjectOnboardingAttempt.t(), keyword()) ::
          {:ok, Project.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, {:repository_already_linked, Project.t()}}
          | {:error, atom()}
  def register_project(
        %PersonalWorkspace{} = workspace,
        %ProjectOnboardingAttempt{} = attempt,
        opts \\ []
      ) do
    cond do
      is_nil(attempt.selected_repository) -> {:error, :repository_required}
      is_nil(attempt.storage_mode) -> {:error, :storage_mode_required}
      not is_nil(attempt.consumed_at) -> committed_project(workspace, attempt)
      not storage_ready?(attempt) -> {:error, :storage_not_ready}
      attempt.storage_mode == "device" -> {:error, :device_registration_not_available}
      true -> do_register(workspace, attempt, opts, 0)
    end
  end

  @doc """
  Renames a project, enforcing workspace-scoped case-insensitive uniqueness while
  keeping project and repository identity stable. A conflict returns an inline
  `{:error, changeset}` on `:name` rather than changing the value. This is the
  reusable rename operation the post-creation control (Task 8) wires to.
  """
  @spec rename_project(Project.t(), String.t()) ::
          {:ok, Project.t()} | {:error, Ecto.Changeset.t()}
  def rename_project(%Project{} = project, new_name) when is_binary(new_name) do
    project
    |> Project.rename_changeset(%{name: new_name})
    |> Repo.update()
  end

  # Runs the registration transaction, retrying suffix allocation on a name
  # collision only when the caller accepted the suggested default.
  defp do_register(workspace, attempt, opts, tries) do
    repo = attempt.selected_repository
    name = registration_name(workspace, attempt, opts)

    case build_and_run(workspace, attempt, repo, name) do
      {:ok, %{project: project}} ->
        {:ok, Repo.preload(project, [:repository_connection, :hosted_storage])}

      {:error, :project, %Ecto.Changeset{} = changeset, _changes} ->
        handle_name_conflict(workspace, attempt, opts, changeset, tries)

      {:error, :connection, %Ecto.Changeset{} = changeset, _changes} ->
        if unique_conflict?(changeset),
          do: {:error, {:repository_already_linked, existing_project_for(workspace, repo)}},
          else: {:error, changeset}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  # One `Ecto.Multi`: insert the project, its canonical repository connection, and
  # (for hosted storage) the storage row, then consume the attempt. Every step
  # commits together or rolls back together.
  defp build_and_run(workspace, attempt, repo, name) do
    {:ok, multi} =
      Multi.new()
      |> Multi.insert(
        :project,
        Project.registration_changeset(%Project{}, %{
          name: name,
          workspace_id: workspace.id,
          storage_mode: attempt.storage_mode,
          onboarding_attempt_id: attempt.id
        })
      )
      |> Multi.insert(:connection, fn %{project: project} ->
        RepositoryConnection.create_changeset(
          %RepositoryConnection{},
          connection_attrs(project, workspace, repo)
        )
      end)
      |> prepare_storage(attempt)

    multi
    |> Multi.update(:attempt, ProjectOnboardingAttempt.consume_changeset(attempt))
    |> Repo.transaction()
  end

  # Hosted storage joins the transaction through the shared adapter contract.
  # Task 4 dispatches device registration to the worker-owned local transaction;
  # device project and connection rows are never written to hosted PostgreSQL.
  defp prepare_storage(multi, %{storage_mode: "hosted"} = attempt),
    do: Hosted.prepare(multi, attempt, [])

  # Hosted is always ready; device requires a valid readiness receipt, checked
  # through the shared ProjectStorage contract.
  defp storage_ready?(%{storage_mode: "hosted"}), do: true

  defp storage_ready?(%{storage_mode: "device"} = attempt),
    do: ProjectStorage.available?(:device, attempt)

  defp storage_ready?(_), do: false

  defp registration_name(workspace, attempt, opts) do
    case Keyword.get(opts, :name) do
      name when is_binary(name) -> name
      _ -> default_project_name(workspace, repository_name(attempt.selected_repository))
    end
  end

  defp handle_name_conflict(workspace, attempt, opts, changeset, tries) do
    cond do
      not name_conflict?(changeset) ->
        {:error, changeset}

      Keyword.get(opts, :allocate_suffix?, false) and tries < @max_suffix_retries ->
        next = default_project_name(workspace, repository_name(attempt.selected_repository))
        do_register(workspace, attempt, Keyword.put(opts, :name, next), tries + 1)

      true ->
        {:error, changeset}
    end
  end

  # Idempotent retry of an already-consumed attempt: return the project it created.
  defp committed_project(%PersonalWorkspace{id: workspace_id}, attempt) do
    query =
      from p in Project,
        where: p.onboarding_attempt_id == ^attempt.id and p.workspace_id == ^workspace_id,
        preload: [:repository_connection, :hosted_storage]

    case Repo.one(query) do
      nil -> {:error, :already_consumed}
      %Project{} = project -> {:ok, project}
    end
  end

  defp existing_project_for(%PersonalWorkspace{id: workspace_id}, repo) do
    provider = repo["provider"] || "github"
    repository_id = repo["repository_id"]

    Repo.one(
      from c in RepositoryConnection,
        join: p in assoc(c, :project),
        where:
          c.workspace_id == ^workspace_id and c.provider == ^provider and
            c.provider_repository_id == ^repository_id,
        select: p
    )
  end

  defp connection_attrs(project, workspace, repo) do
    %{
      project_id: project.id,
      workspace_id: workspace.id,
      provider: repo["provider"] || "github",
      provider_repository_id: repo["repository_id"],
      owner: repo["owner"],
      name: repo["name"],
      full_name: repo["full_name"],
      html_url: repo["html_url"],
      visibility: repo["visibility"],
      private: repo["private"],
      organization: repo["organization"],
      state: "connected",
      last_validated_at: now()
    }
  end

  defp repository_name(repo) when is_map(repo), do: repo["name"] || repo["full_name"] || "project"

  defp default_base(base_name) do
    case String.trim(base_name) do
      "" -> "project"
      trimmed -> trimmed
    end
  end

  defp next_suffixed_name(workspace, base, n) when n <= @max_suffix_retries do
    candidate = "#{base}-#{n}"

    if name_available?(workspace, candidate),
      do: candidate,
      else: next_suffixed_name(workspace, base, n + 1)
  end

  # Fallback for a pathologically crowded workspace: a guaranteed-distinct suffix.
  defp next_suffixed_name(_workspace, base, _n),
    do: "#{base}-#{System.unique_integer([:positive])}"

  defp name_available?(%PersonalWorkspace{id: workspace_id}, name) do
    case Project.name_key(name) do
      nil ->
        false

      key ->
        not Repo.exists?(
          from p in Project, where: p.workspace_id == ^workspace_id and p.name_key == ^key
        )
    end
  end

  defp name_conflict?(%Ecto.Changeset{} = changeset) do
    Enum.any?(changeset.errors, fn {field, {_msg, opts}} ->
      field == :name and Keyword.get(opts, :constraint) == :unique
    end)
  end

  defp unique_conflict?(%Ecto.Changeset{} = changeset) do
    Enum.any?(changeset.errors, fn {_field, {_msg, opts}} ->
      Keyword.get(opts, :constraint) == :unique
    end)
  end

  # Applies a changeset to a workspace-scoped attempt, or reports not_found for an
  # unknown, malformed, or cross-workspace attempt so a foreign attempt is never
  # written.
  defp update_attempt(workspace, attempt_id, change_fun) do
    case get_onboarding_attempt(workspace, attempt_id) do
      nil -> {:error, :not_found}
      %ProjectOnboardingAttempt{} = attempt -> attempt |> change_fun.() |> Repo.update()
    end
  end

  # Persist only the approved metadata, with string keys for stable jsonb storage.
  # Accepts a repository map keyed by either atoms (from the provider) or strings.
  defp selected_metadata(repository) do
    %{
      "provider" => "github",
      "repository_id" => field(repository, :id),
      "owner" => field(repository, :owner),
      "name" => field(repository, :name),
      "full_name" => field(repository, :full_name),
      "private" => field(repository, :private) || false,
      "visibility" => field(repository, :visibility),
      "html_url" => field(repository, :html_url),
      "organization" => field(repository, :organization)
    }
  end

  defp field(repository, key) do
    Map.get(repository, key) || Map.get(repository, Atom.to_string(key))
  end

  defp active_attempt_query(workspace_id) do
    now = now()

    from a in ProjectOnboardingAttempt,
      where: a.workspace_id == ^workspace_id and is_nil(a.consumed_at) and a.expires_at > ^now,
      order_by: [desc: a.inserted_at, desc: a.id],
      limit: 1
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
