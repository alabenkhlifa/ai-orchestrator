defmodule SddOrchestrator.Specifications.SpecificationLifecycle do
  @moduledoc """
  Authorized project-deletion propagation for authoritative specifications.

  Hosted deletion relies on database cascades in the project transaction.
  Device deletion runs through the worker-owned serialized boundary and removes
  the project with every specification aggregate without creating a hosted copy.
  """

  alias SddOrchestrator.Accounts.{DeviceWorkspace, PersonalWorkspace}
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Repo
  alias SddOrchestrator.Specifications.SpecificationAuthorization

  @spec delete_project(PersonalWorkspace.t() | DeviceWorkspace.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def delete_project(%PersonalWorkspace{} = authority, project_id) do
    with {:ok, project} <- SpecificationAuthorization.hosted_project(authority, project_id),
         {:ok, deleted} <- Repo.delete(project) do
      {:ok, %{project_id: deleted.id}}
    end
  end

  def delete_project(%DeviceWorkspace{id: authority_id}, project_id) do
    with {:ok, %DeviceWorkspace{id: ^authority_id}} <- Devices.get_workspace(),
         {:ok, %{storage_mode: "device"}} <- Devices.get_project(project_id) do
      Devices.delete_project(project_id)
    else
      _reason -> {:error, :not_found}
    end
  end

  def delete_project(_authority, _project_id), do: {:error, :not_found}
end
