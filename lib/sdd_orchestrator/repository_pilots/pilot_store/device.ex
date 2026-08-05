defmodule SddOrchestrator.RepositoryPilots.PilotStore.Device do
  @moduledoc "Device-local pilot-store adapter. It writes nothing hosted."

  @behaviour SddOrchestrator.RepositoryPilots.PilotStore

  alias SddOrchestrator.Accounts.DeviceWorkspace
  alias SddOrchestrator.Devices
  alias SddOrchestrator.RepositoryPilots.RepositoryPilotSelection

  @impl true
  def put({:device, %DeviceWorkspace{} = authority}, %RepositoryPilotSelection{} = selection) do
    with {:ok, _project} <- authorize(authority, selection.project_id),
         true <- selection.selected_by_actor_ref == authority.id,
         {:ok, value} <-
           Devices.put_repository_pilot_selection(
             selection.project_id,
             RepositoryPilotSelection.to_value(selection)
           ) do
      RepositoryPilotSelection.from_value(value)
    else
      false -> {:error, :unauthorized}
      {:error, :not_found} -> {:error, :unauthorized}
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, _reason -> {:error, :persistence_failed}
  end

  def put(_authority, _selection), do: {:error, :unsupported_authority}

  @impl true
  def fetch({:device, %DeviceWorkspace{} = authority}, project_id) do
    with {:ok, _project} <- authorize(authority, project_id),
         {:ok, value} <- Devices.get_repository_pilot_selection(project_id),
         {:ok, selection} <- RepositoryPilotSelection.from_value(value) do
      {:ok, selection}
    else
      _missing -> {:error, :not_found}
    end
  catch
    :exit, _reason -> {:error, :not_found}
  end

  def fetch(_viewer, _project_id), do: {:error, :not_found}

  defp authorize(%DeviceWorkspace{id: authority_id} = authority, project_id) do
    with {:ok, %DeviceWorkspace{id: ^authority_id}} <- Devices.get_workspace(),
         {:ok, %{status: "connected"} = project} <- Devices.get_project(project_id),
         true <- DeviceWorkspace.owns_project?(authority, project) do
      {:ok, project}
    else
      _missing -> {:error, :not_found}
    end
  end
end
