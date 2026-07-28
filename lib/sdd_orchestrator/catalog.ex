defmodule SddOrchestrator.Catalog do
  @moduledoc """
  The signed-in combined project catalog.

  Composes two separately authoritative sources into one read-only view:

    * hosted projects owned by the signed-in `PersonalWorkspace`, with their
      repository-connection status; and
    * the on-device projects available on this device through `DeviceWorkspace`,
      with the current worker availability.

  Composition is strictly non-mutating. It never changes project identity,
  ownership, or storage mode, never uploads or synchronizes device data, persists
  no cross-boundary ownership or collision link, and emits no analytics. A device
  project stays owned by `DeviceWorkspace` even while it appears in a signed-in
  catalog.

  If two separately authoritative records share a stable project id — which can
  only arise from a visibility-bounded restore in `specs/06-project-portability/`
  — both remain as their own entries and are flagged as an identity conflict.
  Detection uses only the records already composed in the current session; the
  catalog offers no resolution action in this slice.
  """
  alias SddOrchestrator.Accounts.PersonalWorkspace
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Projects.Connections

  @type availability ::
          :connected | :disconnected | :temporarily_unavailable | :available | :unavailable

  @type entry :: %{
          id: String.t(),
          name: String.t(),
          storage_mode: String.t(),
          availability: availability(),
          repository_label: String.t() | nil,
          route: String.t(),
          identity_conflict?: boolean()
        }

  @doc """
  The combined catalog for a signed-in account and its personal workspace.

  `opts` are forwarded to the hosted connection revalidation (`revalidate:`).
  """
  @spec combined(struct(), PersonalWorkspace.t(), keyword()) :: [entry()]
  def combined(account, %PersonalWorkspace{} = workspace, opts \\ []) do
    (hosted_entries(account, workspace, opts) ++ device_entries())
    |> mark_identity_conflicts()
    |> Enum.sort_by(&{&1.name, &1.id})
  end

  @doc """
  Flags every entry whose stable project id is shared by more than one composed
  record as an identity conflict, keeping each record as its own entry. Uses only
  the records passed in (the current session) and persists nothing — no
  cross-boundary ownership or resolution link, and no authority is chosen.
  """
  @spec mark_identity_conflicts([entry()]) :: [entry()]
  def mark_identity_conflicts(entries) do
    counts = Enum.frequencies_by(entries, & &1.id)

    Enum.map(entries, fn entry ->
      %{entry | identity_conflict?: Map.get(counts, entry.id, 0) > 1}
    end)
  end

  defp hosted_entries(account, workspace, opts) do
    account
    |> Connections.catalog(workspace, opts)
    |> Enum.map(fn entry ->
      %{
        id: entry.project.id,
        name: entry.project.name,
        storage_mode: "hosted",
        availability: entry.status,
        repository_label: entry.connection && entry.connection.full_name,
        route: "/projects/#{entry.project.id}",
        identity_conflict?: false
      }
    end)
  end

  defp device_entries do
    case safe_device_projects() do
      [] ->
        []

      projects ->
        availability = device_availability()

        Enum.map(projects, fn project ->
          %{
            id: project.id,
            name: project.name,
            storage_mode: "device",
            # The repository label is intentionally omitted: a device repository's
            # only identifier is its non-reversible fingerprint, never a shareable
            # name, path, or URL.
            availability: availability,
            repository_label: nil,
            route: "/local/projects/#{project.id}",
            identity_conflict?: false
          }
        end)
    end
  end

  # No device boundary on this host (no worker/store) means no on-device projects
  # to compose. A worker that is absent or unreachable simply contributes nothing
  # rather than failing the whole catalog.
  defp safe_device_projects do
    if device_store_running?(), do: Devices.list_projects(), else: []
  rescue
    _error -> []
  catch
    :exit, _reason -> []
  end

  defp device_availability do
    with true <- device_store_running?(),
         {:ok, workspace} <- Devices.get_workspace() do
      case Devices.worker_status(workspace.id) do
        :detected -> :available
        _other -> :unavailable
      end
    else
      _ -> :unavailable
    end
  rescue
    _error -> :unavailable
  catch
    :exit, _reason -> :unavailable
  end

  defp device_store_running? do
    case Application.get_env(:sdd_orchestrator, Devices) do
      config when is_list(config) ->
        adapter = Keyword.get(config, :adapter)
        is_atom(adapter) and not is_nil(adapter) and not is_nil(Process.whereis(adapter))

      _ ->
        false
    end
  end
end
