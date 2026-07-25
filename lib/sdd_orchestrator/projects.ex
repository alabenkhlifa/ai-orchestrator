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

  defp active_attempt_query(workspace_id) do
    now = now()

    from a in ProjectOnboardingAttempt,
      where: a.workspace_id == ^workspace_id and is_nil(a.consumed_at) and a.expires_at > ^now,
      order_by: [desc: a.inserted_at, desc: a.id],
      limit: 1
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
