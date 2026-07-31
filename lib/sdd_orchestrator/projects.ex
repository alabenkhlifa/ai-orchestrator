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
  alias SddOrchestrator.Accounts.{DeviceWorkspace, PersonalWorkspace}
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.DeviceProject
  alias SddOrchestrator.Participation
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
  @spec select_storage_mode(
          PersonalWorkspace.t() | DeviceWorkspace.t(),
          String.t(),
          String.t()
        ) ::
          {:ok, ProjectOnboardingAttempt.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def select_storage_mode(%PersonalWorkspace{} = workspace, attempt_id, mode)
      when is_binary(attempt_id) and is_binary(mode) do
    update_attempt(workspace, attempt_id, fn attempt ->
      ProjectOnboardingAttempt.select_storage_changeset(attempt, mode)
    end)
  end

  def select_storage_mode(%DeviceWorkspace{} = workspace, attempt_id, mode)
      when is_binary(attempt_id) and is_binary(mode) do
    update_device_attempt(workspace, attempt_id, fn attempt ->
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
  @spec record_device_receipt(
          PersonalWorkspace.t() | DeviceWorkspace.t(),
          String.t(),
          DeviceStorageReceipt.t()
        ) ::
          {:ok, ProjectOnboardingAttempt.t()}
          | {:error,
             :not_found | :receipt_binding_mismatch | :receipt_expired | Ecto.Changeset.t()}
  def record_device_receipt(
        %PersonalWorkspace{} = workspace,
        attempt_id,
        %DeviceStorageReceipt{} = receipt
      )
      when is_binary(attempt_id) do
    store_bound_receipt(get_onboarding_attempt(workspace, attempt_id), receipt, nil)
  end

  def record_device_receipt(
        %DeviceWorkspace{id: device_workspace_id} = workspace,
        attempt_id,
        %DeviceStorageReceipt{} = receipt
      )
      when is_binary(attempt_id) do
    store_bound_receipt(
      get_device_onboarding_attempt(workspace, attempt_id),
      receipt,
      device_workspace_id
    )
  end

  # Stores a readiness receipt only when it is bound to this attempt (and, for a
  # device-origin attempt, this device workspace) and unexpired. A mismatched,
  # replayed, or expired receipt fails closed and writes nothing.
  defp store_bound_receipt(nil, _receipt, _device_workspace_id), do: {:error, :not_found}

  defp store_bound_receipt(%ProjectOnboardingAttempt{} = attempt, receipt, device_workspace_id) do
    cond do
      receipt.attempt_id != attempt.id ->
        {:error, :receipt_binding_mismatch}

      not is_nil(device_workspace_id) and receipt.device_workspace_id != device_workspace_id ->
        {:error, :receipt_binding_mismatch}

      not DeviceStorageReceipt.valid?(receipt) ->
        {:error, :receipt_expired}

      true ->
        attempt
        |> ProjectOnboardingAttempt.device_setup_changeset(DeviceStorageReceipt.to_map(receipt))
        |> Repo.update()
    end
  end

  ## Device-origin (accountless) onboarding attempts

  @doc """
  Starts a fresh device-origin onboarding attempt for accountless local
  onboarding.

  It owns no hosted workspace; it references only the opaque device-workspace id
  and, when supplied, binds to the current browser flow so a later prerequisite
  return cannot be replayed against another browser.
  """
  @spec start_device_onboarding_attempt(DeviceWorkspace.t(), keyword()) ::
          {:ok, ProjectOnboardingAttempt.t()} | {:error, Ecto.Changeset.t()}
  def start_device_onboarding_attempt(%DeviceWorkspace{id: device_workspace_id}, opts \\ []) do
    %ProjectOnboardingAttempt{}
    |> ProjectOnboardingAttempt.create_device_changeset(%{
      device_workspace_id: device_workspace_id,
      idempotency_key: Ecto.UUID.generate(),
      status: "started",
      expires_at: DateTime.add(now(), @attempt_ttl_seconds, :second),
      browser_flow_binding: Keyword.get(opts, :browser_flow_binding)
    })
    |> Repo.insert()
  end

  @doc """
  Fetches a device-origin onboarding attempt scoped to its device workspace.
  Returns nil for a missing, malformed, hosted-origin, or cross-device id so a
  foreign attempt is never resolved.
  """
  @spec get_device_onboarding_attempt(DeviceWorkspace.t(), String.t()) ::
          ProjectOnboardingAttempt.t() | nil
  def get_device_onboarding_attempt(%DeviceWorkspace{id: device_workspace_id}, attempt_id)
      when is_binary(attempt_id) do
    case Ecto.UUID.cast(attempt_id) do
      {:ok, uuid} ->
        Repo.one(
          from a in ProjectOnboardingAttempt,
            where:
              a.id == ^uuid and a.device_workspace_id == ^device_workspace_id and
                a.origin_kind == "device"
        )

      :error ->
        nil
    end
  end

  @doc """
  Records the confirmed local repository on a device-origin attempt. Only the
  device-local canonical fingerprint and display name cross into the transient
  handoff; no path, remote URL, filename, or source content is stored.
  """
  @spec select_local_repository(DeviceWorkspace.t(), String.t(), map()) ::
          {:ok, ProjectOnboardingAttempt.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def select_local_repository(%DeviceWorkspace{} = workspace, attempt_id, repository)
      when is_binary(attempt_id) and is_map(repository) do
    update_device_attempt(workspace, attempt_id, fn attempt ->
      ProjectOnboardingAttempt.select_repository_changeset(attempt, local_metadata(repository))
    end)
  end

  @doc """
  Records the hosted workspace proven by a verified sign-in on a device-origin
  attempt, making hosted storage available. Never selects a mode or creates a
  project. Returns `{:error, :not_found}` for a foreign attempt.
  """
  @spec record_hosted_prerequisite(DeviceWorkspace.t(), String.t(), PersonalWorkspace.t()) ::
          {:ok, ProjectOnboardingAttempt.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def record_hosted_prerequisite(
        %DeviceWorkspace{} = workspace,
        attempt_id,
        %PersonalWorkspace{id: hosted_workspace_id}
      )
      when is_binary(attempt_id) do
    update_device_attempt(workspace, attempt_id, fn attempt ->
      ProjectOnboardingAttempt.hosted_prerequisite_changeset(attempt, hosted_workspace_id)
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
  Registers an on-device project for a confirmed device-origin attempt.

  The device store owns the worker transaction that commits the project, its
  repository connection (the canonical fingerprint), and the device storage mode
  atomically under the operating-system boundary — nothing device-authoritative is
  written to hosted PostgreSQL. The commit is idempotent by the attempt's
  idempotency key, so a committed retry or a lost control-plane acknowledgement
  resolves to the already-created project without a duplicate. After the local
  commit, the transient control-plane attempt is acknowledged by consuming it; a
  failed acknowledgement is reconciled on the next attempt through the same
  idempotency key rather than by rolling back committed device data.

  Requires an explicitly selected, available device mode; returns
  `:storage_mode_required` or `:storage_not_ready` otherwise so a project is never
  created without a usable storage boundary.
  """
  @spec register_device_project(DeviceWorkspace.t(), ProjectOnboardingAttempt.t(), keyword()) ::
          {:ok, DeviceProject.t()}
          | {:error,
             :repository_required
             | :storage_mode_required
             | :storage_not_ready
             | :name_taken
             | {:repository_already_linked, DeviceProject.t()}
             | term()}
  def register_device_project(
        %DeviceWorkspace{} = workspace,
        %ProjectOnboardingAttempt{} = attempt,
        opts \\ []
      ) do
    cond do
      is_nil(attempt.selected_repository) -> {:error, :repository_required}
      attempt.storage_mode != "device" -> {:error, :storage_mode_required}
      not ProjectStorage.available?(:device, attempt) -> {:error, :storage_not_ready}
      true -> do_register_device(workspace, attempt, opts)
    end
  end

  defp do_register_device(workspace, attempt, opts) do
    repo = attempt.selected_repository

    attrs = %{
      name: Keyword.get(opts, :name) || repo["name"] || "project",
      repository_fingerprint: repo["fingerprint"],
      status: "connected",
      idempotency_key: attempt.idempotency_key
    }

    case Devices.register_project(attrs, Keyword.take(opts, [:allocate_suffix?])) do
      {:ok, %DeviceProject{} = project} ->
        # Acknowledge the transient control-plane attempt. If this fails, the
        # committed device project stays reconcilable by its idempotency key.
        _ = acknowledge_device_attempt(workspace, attempt)
        {:ok, project}

      {:error, _reason} = error ->
        error
    end
  end

  defp acknowledge_device_attempt(workspace, attempt) do
    update_device_attempt(workspace, attempt.id, &ProjectOnboardingAttempt.consume_changeset/1)
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
        handle_project_conflict(workspace, attempt, repo, opts, changeset, tries)

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
          onboarding_attempt_id: attempt.id,
          repository_provider: repo["provider"] || "github",
          canonical_repository_id: to_string(repo["repository_id"])
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
    |> prepare_owner_profile(workspace, attempt)
    |> Multi.update(:attempt, ProjectOnboardingAttempt.consume_changeset(attempt))
    |> Repo.transaction()
  end

  # The owner's project display profile is part of the project, not a later
  # setup step: a project that committed without one would deny its own creator
  # a label on every collaboration surface. The label is derived from the
  # owner's GitHub login and never from their email, and it joins the same
  # transaction so a failed profile rolls the whole registration back.
  defp prepare_owner_profile(multi, %PersonalWorkspace{} = workspace, %{storage_mode: "hosted"}) do
    Multi.insert(multi, :owner_profile, fn %{project: project} ->
      Participation.initial_owner_profile_changeset(project.id, workspace.account_id)
    end)
  end

  defp prepare_owner_profile(multi, _workspace, _attempt), do: multi

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

  defp handle_project_conflict(workspace, attempt, repo, opts, changeset, tries) do
    if constraint_conflict?(changeset, :projects_workspace_repository_identity_index) do
      {:error, {:repository_already_linked, existing_project_for(workspace, repo)}}
    else
      handle_name_conflict(workspace, attempt, opts, changeset, tries)
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
    repository_id = to_string(repo["repository_id"])

    Repo.one(
      from p in Project,
        where:
          p.workspace_id == ^workspace_id and p.repository_provider == ^provider and
            p.canonical_repository_id == ^repository_id
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

  defp constraint_conflict?(%Ecto.Changeset{} = changeset, constraint_name) do
    Enum.any?(changeset.errors, fn {_field, {_msg, opts}} ->
      to_string(Keyword.get(opts, :constraint_name)) == to_string(constraint_name)
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

  # Device-scoped counterpart: applies a changeset to a device-origin attempt, or
  # reports not_found for an unknown, malformed, hosted-origin, or cross-device
  # attempt so a foreign attempt is never written.
  defp update_device_attempt(workspace, attempt_id, change_fun) do
    case get_device_onboarding_attempt(workspace, attempt_id) do
      nil -> {:error, :not_found}
      %ProjectOnboardingAttempt{} = attempt -> attempt |> change_fun.() |> Repo.update()
    end
  end

  # The approved minimum local-repository metadata: provider, the non-reversible
  # canonical fingerprint, and the display name. No path, remote URL, filename,
  # Git history, or source content is stored.
  defp local_metadata(repository) do
    %{
      "provider" => "local",
      "fingerprint" => field(repository, :fingerprint),
      "name" => field(repository, :name)
    }
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
