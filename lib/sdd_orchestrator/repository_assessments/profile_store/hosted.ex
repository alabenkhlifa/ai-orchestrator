defmodule SddOrchestrator.RepositoryAssessments.ProfileStore.Hosted do
  @moduledoc "PostgreSQL append-only profile-store adapter for hosted projects."

  @behaviour SddOrchestrator.RepositoryAssessments.ProfileStore

  import Ecto.Query

  alias SddOrchestrator.Participation
  alias SddOrchestrator.Projects.{Project, RepositoryConnection}
  alias SddOrchestrator.Repo

  alias SddOrchestrator.RepositoryAssessments.{
    RepositoryAssessment,
    RepositoryExecutionProfile,
    RepositoryExecutionProfileProposal
  }

  @impl true
  def append(
        {:hosted, account_id},
        %RepositoryAssessment{} = assessment,
        %RepositoryExecutionProfileProposal{} = proposal,
        actor_ref,
        %DateTime{} = approved_at
      ) do
    with true <- actor_ref == account_id,
         true <- RepositoryAssessment.strict?(assessment),
         true <- assessment.state == "completed",
         true <- RepositoryAssessment.cache_provenance_complete?(assessment),
         true <- RepositoryExecutionProfileProposal.matches_assessment?(proposal, assessment) do
      append_transaction(account_id, assessment, proposal, actor_ref, approved_at)
    else
      _invalid -> {:error, :stale_assessment}
    end
  rescue
    Ecto.Query.CastError -> {:error, :unauthorized}
  end

  def append(_authority, _assessment, _proposal, _actor_ref, _approved_at),
    do: {:error, :unsupported_authority}

  @impl true
  def list(viewer, project_id) do
    with {:ok, project} <- authorize_viewer(viewer, project_id) do
      RepositoryExecutionProfile
      |> where([profile], profile.project_id == ^project.id)
      |> order_by([profile], asc: profile.version)
      |> Repo.all()
    else
      _missing -> []
    end
  rescue
    Ecto.Query.CastError -> []
  end

  defp authorize_viewer({:hosted, account_id}, project_id) do
    with {:ok, project} <- Participation.owned_project(account_id, project_id),
         true <- active_hosted_project?(project) do
      {:ok, project}
    else
      _unauthorized -> {:error, :not_found}
    end
  end

  defp authorize_viewer({:participant, account_id, hosted_identity_id}, project_id) do
    with {:ok, project, role} <-
           Participation.visible_project(project_id, account_id, hosted_identity_id),
         true <- role in [:owner, :participant],
         true <- active_hosted_project?(project) do
      {:ok, project}
    else
      _unauthorized -> {:error, :not_found}
    end
  end

  defp authorize_viewer(_viewer, _project_id), do: {:error, :not_found}

  defp active_hosted_project?(project),
    do: project.storage_mode == "hosted" and project.lifecycle_state == "active"

  @impl true
  def count(authority, project_id), do: length(list(authority, project_id))

  defp append_transaction(account_id, assessment, proposal, actor_ref, approved_at) do
    case Repo.transaction(fn ->
           with %Project{} = project <- lock_project_binding(assessment.project_id),
                {:ok, owned} <- Participation.owned_project(account_id, assessment.project_id),
                true <- owned.id == project.id,
                true <- active_binding?(project, assessment),
                %RepositoryAssessment{} = current <- lock_assessment(assessment),
                true <- RepositoryAssessment.cache_provenance_complete?(current),
                %RepositoryAssessment{id: current_id} <- latest_assessment(assessment.project_id),
                true <- current_id == current.id,
                true <- RepositoryExecutionProfileProposal.matches_assessment?(proposal, current) do
             append_or_replay(proposal, actor_ref, approved_at)
           else
             false -> Repo.rollback(:stale_assessment)
             nil -> Repo.rollback(:stale_assessment)
             _invalid -> Repo.rollback(:unauthorized)
           end
         end) do
      {:ok, %RepositoryExecutionProfile{} = profile} -> {:ok, profile}
      {:error, reason} when reason in [:stale_assessment, :unauthorized] -> {:error, reason}
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
      {:error, _reason} -> {:error, :persistence_failed}
    end
  end

  defp append_or_replay(proposal, actor_ref, approved_at) do
    case existing_proposal(proposal) do
      %RepositoryExecutionProfile{} = existing ->
        existing

      nil ->
        version = next_version(proposal.project_id)

        with {:ok, profile} <-
               RepositoryExecutionProfile.approved(proposal, actor_ref, version, approved_at),
             {:ok, persisted} <-
               profile
               |> RepositoryExecutionProfile.create_changeset()
               |> Repo.insert() do
          persisted
        else
          {:error, reason} -> Repo.rollback(reason)
        end
    end
  end

  defp existing_proposal(proposal) do
    RepositoryExecutionProfile
    |> where(
      [profile],
      profile.project_id == ^proposal.project_id and
        profile.assessment_id == ^proposal.assessment_id and
        profile.proposal_digest == ^proposal.proposal_digest
    )
    |> Repo.one()
  end

  defp next_version(project_id) do
    current =
      RepositoryExecutionProfile
      |> where([profile], profile.project_id == ^project_id)
      |> select([profile], max(profile.version))
      |> Repo.one()

    (current || 0) + 1
  end

  defp lock_assessment(assessment) do
    RepositoryAssessment
    |> where(
      [current],
      current.id == ^assessment.id and current.project_id == ^assessment.project_id and
        current.state == "completed"
    )
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp latest_assessment(project_id) do
    RepositoryAssessment
    |> where([assessment], assessment.project_id == ^project_id)
    |> order_by([assessment], desc: assessment.inserted_at, desc: assessment.id)
    |> limit(1)
    |> Repo.one()
  end

  defp active_binding?(project, assessment) do
    project.storage_mode == "hosted" and project.lifecycle_state == "active" and
      project.repository_provider == assessment.repository_provider and
      project.canonical_repository_id == assessment.repository_id and
      match?(%{state: "connected"}, project.repository_connection)
  end

  defp lock_project_binding(project_id) do
    project =
      Project
      |> where([project], project.id == ^project_id)
      |> lock("FOR UPDATE")
      |> Repo.one()

    connection =
      RepositoryConnection
      |> where([connection], connection.project_id == ^project_id)
      |> lock("FOR UPDATE")
      |> Repo.one()

    case {project, connection} do
      {%Project{} = project, %RepositoryConnection{} = connection} ->
        %{project | repository_connection: connection}

      _missing ->
        nil
    end
  end
end
