defmodule SddOrchestrator.Participation do
  @moduledoc """
  Hosted-project participation: the immutable owner, active participant
  authorizations, and the project-specific presentation profiles that label
  them.

  Authorization is read directly for every protected action rather than cached,
  so removal and leave take effect immediately. Nothing here mutates another
  specification's records; feature-delivery consumers read the current result
  and apply their own behavior.
  """

  import Ecto.Query

  alias SddOrchestrator.Accounts.PersonalWorkspace
  alias SddOrchestrator.Participation.{ProjectMemberProfile, ProjectParticipant}
  alias SddOrchestrator.Projects.Project
  alias SddOrchestrator.Repo

  @type owner :: %{
          project_id: Ecto.UUID.t(),
          workspace_id: Ecto.UUID.t(),
          account_id: Ecto.UUID.t()
        }

  @doc """
  Derives the immutable project owner from the hosted project ownership
  boundary.

  A device-authoritative project has no hosted owner and cannot participate in
  hosted collaboration.
  """
  @spec owner(Project.t() | Ecto.UUID.t()) ::
          {:ok, owner()} | {:error, :not_hosted_project | :project_not_found}
  def owner(%Project{} = project), do: owner_for(project)

  def owner(project_id) when is_binary(project_id) do
    case Repo.get(Project, project_id) do
      nil -> {:error, :project_not_found}
      project -> owner_for(project)
    end
  rescue
    Ecto.Query.CastError -> {:error, :project_not_found}
  end

  def owner(_project), do: {:error, :project_not_found}

  @doc "Returns true only when the account is the current immutable project owner."
  @spec owner?(Project.t() | Ecto.UUID.t(), Ecto.UUID.t() | nil) :: boolean()
  def owner?(_project, nil), do: false

  def owner?(project, account_id) do
    case owner(project) do
      {:ok, %{account_id: ^account_id}} -> true
      _other -> false
    end
  end

  @doc """
  Returns the current active participant authorization for one hosted identity
  and project, or `nil` when it is absent, removed, or left.
  """
  @spec active_participant(Ecto.UUID.t(), Ecto.UUID.t() | nil) :: ProjectParticipant.t() | nil
  def active_participant(_project_id, nil), do: nil

  def active_participant(project_id, hosted_identity_id) do
    ProjectParticipant
    |> where(
      [p],
      p.project_id == ^project_id and p.hosted_identity_id == ^hosted_identity_id and
        p.state == "active"
    )
    |> Repo.one()
  rescue
    Ecto.Query.CastError -> nil
  end

  @doc "Lists the current active participant authorizations of one project."
  @spec active_participants(Ecto.UUID.t()) :: [ProjectParticipant.t()]
  def active_participants(project_id) do
    ProjectParticipant
    |> where([p], p.project_id == ^project_id and p.state == "active")
    |> order_by([p], asc: p.joined_at, asc: p.id)
    |> Repo.all()
  end

  @doc "Returns the current project profile of one account, when it exists."
  @spec member_profile(Ecto.UUID.t(), Ecto.UUID.t() | nil) :: ProjectMemberProfile.t() | nil
  def member_profile(_project_id, nil), do: nil

  def member_profile(project_id, account_id) do
    ProjectMemberProfile
    |> where([p], p.project_id == ^project_id and p.account_id == ^account_id)
    |> Repo.one()
  rescue
    Ecto.Query.CastError -> nil
  end

  @doc "Returns the current owner profile of one project, when it exists."
  @spec owner_profile(Ecto.UUID.t()) :: ProjectMemberProfile.t() | nil
  def owner_profile(project_id) do
    ProjectMemberProfile
    |> where([p], p.project_id == ^project_id and p.role == "owner" and p.state == "active")
    |> Repo.one()
  end

  defp owner_for(%Project{storage_mode: "hosted"} = project) do
    PersonalWorkspace
    |> where([w], w.id == ^project.workspace_id)
    |> select([w], w.account_id)
    |> Repo.one()
    |> case do
      nil ->
        {:error, :not_hosted_project}

      account_id ->
        {:ok,
         %{project_id: project.id, workspace_id: project.workspace_id, account_id: account_id}}
    end
  end

  defp owner_for(%Project{}), do: {:error, :not_hosted_project}
end
