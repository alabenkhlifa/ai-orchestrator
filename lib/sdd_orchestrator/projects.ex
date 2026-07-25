defmodule SddOrchestrator.Projects do
  @moduledoc """
  Projects context: the workspace-scoped project catalog and the short-lived
  onboarding-attempt lifecycle.

  This task owns the read side of the catalog (`list_catalog/1`,
  `has_projects?/1`) and the creation of onboarding attempts. Attempts are always
  scoped to a personal workspace, so a catalog query or attempt lookup can never
  cross the workspace ownership boundary. The project-registration transaction,
  naming, and repository connection are owned by the confirmation task.
  """
  import Ecto.Query

  alias SddOrchestrator.Accounts.PersonalWorkspace
  alias SddOrchestrator.Projects.{Project, ProjectOnboardingAttempt}
  alias SddOrchestrator.ProjectStorage.DeviceStorageReceipt
  alias SddOrchestrator.Repo

  # Abandoned onboarding attempts become unusable after this window and are
  # pruned by the retention job (approved development privacy contract).
  @attempt_ttl_seconds 24 * 60 * 60

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
