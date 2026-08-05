defmodule SddOrchestrator.RepositoryPilots.PilotStore.Hosted do
  @moduledoc "PostgreSQL pilot-store adapter for hosted projects."

  @behaviour SddOrchestrator.RepositoryPilots.PilotStore

  import Ecto.Query

  alias SddOrchestrator.Participation
  alias SddOrchestrator.Repo
  alias SddOrchestrator.RepositoryPilots.RepositoryPilotSelection

  @impl true
  def put({:hosted, account_id}, %RepositoryPilotSelection{} = selection) do
    with {:ok, project} <- authorize_viewer({:hosted, account_id}, selection.project_id),
         true <- project.id == selection.project_id,
         true <- selection.selected_by_actor_ref == account_id do
      upsert(selection)
    else
      _unauthorized -> {:error, :unauthorized}
    end
  rescue
    Ecto.Query.CastError -> {:error, :unauthorized}
  end

  def put(_authority, _selection), do: {:error, :unsupported_authority}

  @impl true
  def fetch(viewer, project_id) do
    with {:ok, project} <- authorize_viewer(viewer, project_id),
         %RepositoryPilotSelection{} = selection <- current(project.id) do
      {:ok, selection}
    else
      _missing -> {:error, :not_found}
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_found}
  end

  # Re-selection replaces the project's single current pilot rather than
  # accumulating a second authority for the same project.
  defp upsert(selection) do
    selection
    |> RepositoryPilotSelection.create_changeset()
    |> Repo.insert(
      conflict_target: :project_id,
      on_conflict:
        {:replace,
         [
           :id,
           :profile_id,
           :profile_version,
           :specification_id,
           :revision_id,
           :revision_digest,
           :selected_by_actor_ref,
           :selected_at,
           :inserted_at
         ]}
    )
    |> case do
      {:ok, stored} -> {:ok, stored}
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
    end
  end

  defp current(project_id) do
    RepositoryPilotSelection
    |> where([selection], selection.project_id == ^project_id)
    |> Repo.one()
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
end
