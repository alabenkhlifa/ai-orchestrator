defmodule SddOrchestrator.Devices.DeviceStoreTest do
  @moduledoc """
  Task 1 proof: the accountless device-workspace boundary persists under the
  operating-system boundary, derives ownership without a hosted identity, and
  treats data loss as a fresh start rather than a restoration.

  The repository-reconnection-is-not-history-restoration proof is completed with
  Task 4, where a repository connection exists to reconnect.
  """
  use ExUnit.Case, async: false

  alias SddOrchestrator.Accounts.DeviceWorkspace
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.DeviceStore.Local

  setup do
    path = store_path()
    on_exit(fn -> File.rm_rf!(Path.dirname(path)) end)
    start_supervised!({Local, path: path})
    %{path: path}
  end

  test "establishes one stable accountless device workspace" do
    assert {:ok, %DeviceWorkspace{id: id}} = Devices.establish_workspace()
    assert is_binary(id)
    assert {:ok, %DeviceWorkspace{id: ^id}} = Devices.establish_workspace()
    assert {:ok, %DeviceWorkspace{id: ^id}} = Devices.get_workspace()
  end

  test "derives ownership from the device boundary, never a hosted identity" do
    {:ok, workspace} = Devices.establish_workspace()

    refute Map.has_key?(Map.from_struct(workspace), :account_id)

    assert DeviceWorkspace.owns_project?(workspace, %{
             workspace_id: workspace.id,
             storage_mode: "device"
           })

    refute DeviceWorkspace.owns_project?(workspace, %{
             workspace_id: Ecto.UUID.generate(),
             storage_mode: "device"
           })

    refute DeviceWorkspace.owns_project?(workspace, %{
             workspace_id: workspace.id,
             storage_mode: "hosted"
           })
  end

  test "keeps the workspace stable across a restart under the same boundary", %{path: path} do
    {:ok, %DeviceWorkspace{id: id}} = Devices.establish_workspace()

    stop_supervised!(Local)
    start_supervised!({Local, path: path})

    assert {:ok, %DeviceWorkspace{id: ^id}} = Devices.get_workspace()
  end

  test "treats lost device data as a fresh start, never a restoration" do
    {:ok, %DeviceWorkspace{id: lost_id}} = Devices.establish_workspace()

    # Losing the device boundary means the prior store is gone with no hosted copy.
    stop_supervised!(Local)
    fresh_path = store_path()
    on_exit(fn -> File.rm_rf!(Path.dirname(fresh_path)) end)
    start_supervised!({Local, path: fresh_path})

    assert {:error, :not_found} = Devices.get_workspace()
    assert {:ok, %DeviceWorkspace{id: fresh_id}} = Devices.establish_workspace()
    refute fresh_id == lost_id
  end

  defp store_path do
    dir = Path.join(System.tmp_dir!(), "sdd_device_store_#{System.unique_integer([:positive])}")
    Path.join(dir, "store.dets")
  end
end
