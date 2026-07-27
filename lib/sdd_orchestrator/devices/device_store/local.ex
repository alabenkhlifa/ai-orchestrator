defmodule SddOrchestrator.Devices.DeviceStore.Local do
  @moduledoc """
  Development and verification `DeviceStore` adapter.

  Persists the accountless device workspace on the local host with DETS, standing
  in for the release-gated native worker. Durability makes "stable access under
  the same operating-system boundary" and "data loss" distinct events: a lost
  store (a deleted file) yields a fresh workspace, never a restored one.

  Nothing here writes device-authoritative data to the hosted database.
  """

  @behaviour SddOrchestrator.Devices.DeviceStore

  use GenServer

  alias SddOrchestrator.Accounts.{DeviceWorkspace, Workspace}

  @workspace_key :device_workspace

  @doc false
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl SddOrchestrator.Devices.DeviceStore
  def establish_workspace, do: GenServer.call(__MODULE__, :establish_workspace)

  @impl SddOrchestrator.Devices.DeviceStore
  def get_workspace, do: GenServer.call(__MODULE__, :get_workspace)

  @impl GenServer
  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    table = Keyword.get(opts, :table, __MODULE__)
    File.mkdir_p!(Path.dirname(path))
    {:ok, ^table} = :dets.open_file(table, file: String.to_charlist(path), type: :set)
    {:ok, %{table: table}}
  end

  @impl GenServer
  def handle_call(:get_workspace, _from, state) do
    {:reply, fetch(state.table), state}
  end

  def handle_call(:establish_workspace, _from, state) do
    reply =
      case fetch(state.table) do
        {:ok, workspace} -> {:ok, workspace}
        {:error, :not_found} -> create(state.table)
      end

    {:reply, reply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    _ = :dets.close(state.table)
    :ok
  end

  defp fetch(table) do
    case :dets.lookup(table, @workspace_key) do
      [{@workspace_key, id}] -> {:ok, %DeviceWorkspace{id: id}}
      [] -> {:error, :not_found}
    end
  end

  defp create(table) do
    with {:ok, root} <- Workspace.device_root(),
         {:ok, workspace} <- DeviceWorkspace.from_workspace(root) do
      :ok = :dets.insert(table, {@workspace_key, workspace.id})
      :ok = :dets.sync(table)
      {:ok, workspace}
    end
  end
end
