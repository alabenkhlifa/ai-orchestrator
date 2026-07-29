defmodule SddOrchestrator.Portability.RestorePreflight do
  @moduledoc """
  Visibility-bounded stable-project-identity preflight.

  The selected destination is always checked. Additional authorities are checked
  only when the current restore session already holds them, and a device
  authority contributes only while its worker is currently detected. The
  preflight performs no sign-in, worker wake-up, global lookup, persistence,
  telemetry, synchronization, or authority selection.

  This is an advisory check before conflict decisions. The destination adapters
  must repeat their identity constraint inside the atomic restore transaction.
  """

  alias SddOrchestrator.Accounts.{DeviceWorkspace, PersonalWorkspace}
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Portability.{PackageSection, ProjectPackage}
  alias SddOrchestrator.Projects

  @type authority :: PersonalWorkspace.t() | DeviceWorkspace.t()
  @type boundary :: :hosted | :device
  @type available_result :: %{
          project_id: Ecto.UUID.t(),
          checked_boundaries: [boundary()]
        }
  @type conflict_result :: %{
          project_id: Ecto.UUID.t(),
          boundaries: [boundary()]
        }

  @doc """
  Checks the packaged stable project id in the selected destination and in any
  other authority already accessible to this restore session.

  A missing or unavailable non-selected boundary is omitted rather than queried.
  An unavailable selected destination fails because its normal authorization no
  longer holds.
  """
  @spec check_identity(ProjectPackage.t(), authority(), [authority()]) ::
          {:ok, available_result()}
          | {:error, {:same_identity, conflict_result()}}
          | {:error, :destination_unavailable | :invalid_package}
  def check_identity(package, selected_authority, session_authorities \\ [])

  def check_identity(
        %ProjectPackage{
          project: %PackageSection{
            name: :project,
            content: %{"id" => packaged_project_id}
          }
        },
        selected_authority,
        session_authorities
      )
      when is_list(session_authorities) do
    with {:ok, project_id} <- cast_project_id(packaged_project_id),
         {:ok, selected_check} <- check_selected(selected_authority, project_id) do
      checks =
        session_authorities
        |> Enum.reject(&(authority_key(&1) == authority_key(selected_authority)))
        |> Enum.uniq_by(&authority_key/1)
        |> Enum.flat_map(&check_accessible(&1, project_id))

      identity_result(project_id, [selected_check | checks])
    end
  end

  def check_identity(_package, _selected_authority, _session_authorities),
    do: {:error, :invalid_package}

  defp cast_project_id(project_id) do
    case Ecto.UUID.cast(project_id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :invalid_package}
    end
  end

  defp check_selected(%PersonalWorkspace{} = authority, project_id),
    do: {:ok, hosted_check(authority, project_id)}

  defp check_selected(%DeviceWorkspace{} = authority, project_id) do
    if device_available?(authority) do
      case device_check(project_id) do
        {:ok, check} -> {:ok, check}
        {:error, :unavailable} -> {:error, :destination_unavailable}
      end
    else
      {:error, :destination_unavailable}
    end
  end

  defp check_selected(_authority, _project_id), do: {:error, :destination_unavailable}

  defp check_accessible(%PersonalWorkspace{} = authority, project_id),
    do: [hosted_check(authority, project_id)]

  defp check_accessible(%DeviceWorkspace{} = authority, project_id) do
    if device_available?(authority) do
      case device_check(project_id) do
        {:ok, check} -> [check]
        {:error, :unavailable} -> []
      end
    else
      []
    end
  end

  defp check_accessible(_authority, _project_id), do: []

  defp hosted_check(authority, project_id) do
    {:hosted, not is_nil(Projects.get_project(authority, project_id))}
  end

  defp device_check(project_id) do
    case Devices.get_project(project_id) do
      {:ok, _project} -> {:ok, {:device, true}}
      {:error, :not_found} -> {:ok, {:device, false}}
    end
  rescue
    _error -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp device_available?(%DeviceWorkspace{id: workspace_id}) do
    Devices.worker_status(workspace_id) == :detected
  end

  defp identity_result(project_id, checks) do
    checked_boundaries =
      checks
      |> Enum.map(&elem(&1, 0))
      |> Enum.uniq()
      |> Enum.sort()

    conflict_boundaries =
      checks
      |> Enum.filter(&elem(&1, 1))
      |> Enum.map(&elem(&1, 0))
      |> Enum.uniq()
      |> Enum.sort()

    case conflict_boundaries do
      [] ->
        {:ok, %{project_id: project_id, checked_boundaries: checked_boundaries}}

      boundaries ->
        {:error, {:same_identity, %{project_id: project_id, boundaries: boundaries}}}
    end
  end

  defp authority_key(%PersonalWorkspace{id: id}), do: {:hosted, id}
  defp authority_key(%DeviceWorkspace{id: id}), do: {:device, id}
  defp authority_key(_authority), do: :unknown
end
