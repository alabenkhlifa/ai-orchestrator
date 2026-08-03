defmodule SddOrchestrator.RepositoryAssessments.AssessmentStore.Hosted do
  @moduledoc "PostgreSQL assessment-store adapter for hosted projects."

  @behaviour SddOrchestrator.RepositoryAssessments.AssessmentStore

  import Ecto.Query

  alias SddOrchestrator.Participation
  alias SddOrchestrator.Repo
  alias SddOrchestrator.RepositoryAssessments.RepositoryAssessment

  @impl true
  def put({:hosted, account_id}, %RepositoryAssessment{} = assessment) do
    with {:ok, project} <- Participation.owned_project(account_id, assessment.project_id),
         project <- Repo.preload(project, :repository_connection),
         true <- active_hosted_binding?(project, assessment) do
      Repo.insert(assessment)
    else
      _invalid -> {:error, :unauthorized}
    end
  rescue
    Ecto.Query.CastError -> {:error, :unauthorized}
  end

  def put(_authority, _assessment), do: {:error, :unsupported_authority}

  @impl true
  def fetch({:hosted, account_id}, project_id, assessment_id) do
    with {:ok, project} <- Participation.owned_project(account_id, project_id),
         true <- project.storage_mode == "hosted" and project.lifecycle_state == "active",
         %RepositoryAssessment{} = assessment <-
           RepositoryAssessment
           |> where([a], a.project_id == ^project_id and a.id == ^assessment_id)
           |> Repo.one() do
      {:ok, assessment}
    else
      _missing -> {:error, :not_found}
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_found}
  end

  def fetch(_authority, _project_id, _assessment_id), do: {:error, :not_found}

  @impl true
  def count({:hosted, account_id}, project_id) do
    with {:ok, project} <- Participation.owned_project(account_id, project_id),
         true <- project.storage_mode == "hosted" and project.lifecycle_state == "active" do
      RepositoryAssessment
      |> where([a], a.project_id == ^project_id)
      |> Repo.aggregate(:count)
    else
      _missing -> 0
    end
  rescue
    Ecto.Query.CastError -> 0
  end

  def count(_authority, _project_id), do: 0

  defp active_hosted_binding?(project, assessment) do
    project.storage_mode == "hosted" and project.lifecycle_state == "active" and
      project.repository_provider == assessment.repository_provider and
      project.canonical_repository_id == assessment.repository_id and
      match?(%{state: "connected"}, project.repository_connection)
  end
end
