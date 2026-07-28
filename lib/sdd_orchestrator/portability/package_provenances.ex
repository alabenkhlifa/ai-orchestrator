defmodule SddOrchestrator.Portability.PackageProvenances do
  @moduledoc """
  Project-authorized access and lifecycle operations for minimal restore provenance.

  Hosted records are scoped through the owning personal workspace. Device records
  remain behind the current device-workspace boundary. Service termination removes
  hosted provenance without exposing or inventing a source identity.
  """

  import Ecto.Query

  alias SddOrchestrator.Accounts.{DeviceWorkspace, PersonalWorkspace}
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Portability.PackageProvenance
  alias SddOrchestrator.Projects.Project
  alias SddOrchestrator.Repo

  @doc "Returns one minimal provenance only through its current project authority."
  @spec get(PersonalWorkspace.t() | DeviceWorkspace.t(), String.t()) ::
          {:ok, PackageProvenance.t()} | {:error, :not_found}
  def get(%PersonalWorkspace{id: workspace_id}, project_id) when is_binary(project_id) do
    query =
      from provenance in PackageProvenance,
        join: project in Project,
        on: project.id == provenance.project_id,
        where: project.id == ^project_id and project.workspace_id == ^workspace_id,
        select: provenance

    case Repo.one(query) do
      %PackageProvenance{} = provenance -> {:ok, provenance}
      nil -> {:error, :not_found}
    end
  end

  def get(%DeviceWorkspace{id: authority_id}, project_id) when is_binary(project_id) do
    with {:ok, %DeviceWorkspace{id: ^authority_id}} <- Devices.get_workspace(),
         {:ok, %{id: ^project_id, workspace_id: ^authority_id, storage_mode: "device"}} <-
           Devices.get_project(project_id),
         {:ok, %PackageProvenance{project_id: ^project_id} = provenance} <-
           Devices.get_package_provenance(project_id) do
      {:ok, provenance}
    else
      _not_authorized_or_missing -> {:error, :not_found}
    end
  end

  def get(_authority, _project_id), do: {:error, :not_found}

  @doc "Deletes all hosted provenance when the hosted service terminates."
  @spec delete_all_for_service_termination() :: {:ok, non_neg_integer()}
  def delete_all_for_service_termination do
    {count, _} = Repo.delete_all(PackageProvenance)
    {:ok, count}
  end
end
