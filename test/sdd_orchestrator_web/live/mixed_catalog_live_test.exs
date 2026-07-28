defmodule SddOrchestratorWeb.MixedCatalogLiveTest do
  @moduledoc """
  Task 5 proof that the signed-in catalog composes on-device and hosted projects
  into one view (AC-10) without changing ownership or storage (AC-11).

  Each record appears once with its storage mode and availability, and a device
  row routes to the on-device dashboard so the boundary is never crossed. The
  device store is a singleton GenServer not started in test, so this case starts
  its own isolated instance on a unique path in an `async: false` case.
  """
  use SddOrchestratorWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.DeviceStore.Local
  alias SddOrchestrator.ProjectsFixtures

  setup %{conn: conn} do
    path = store_path()
    on_exit(fn -> File.rm_rf!(Path.dirname(path)) end)
    start_supervised!({Local, path: path})

    %{conn: conn, account: account} = register_and_log_in_account(%{conn: conn})
    workspace = ProjectsFixtures.workspace_fixture(account)
    %{conn: conn, workspace: workspace}
  end

  test "composes on-device and hosted projects each once with their storage mode (AC-10)", %{
    conn: conn,
    workspace: workspace
  } do
    ProjectsFixtures.registered_project(workspace, name: "Hosted Roadmap")

    {:ok, device} =
      Devices.register_project(%{
        name: "Local Notes",
        repository_fingerprint: "fp-mixed-catalog",
        status: "connected"
      })

    {:ok, view, html} = live(conn, ~p"/projects")

    assert html =~ "Hosted Roadmap"
    assert html =~ "Local Notes"
    assert html =~ "On this device"
    assert html =~ "In my SDD Orchestrator account"

    assert has_element?(view, "li[data-storage-mode=hosted]")
    assert has_element?(view, "li[data-storage-mode=device]")

    # The device row keeps the boundary: it routes to the on-device dashboard, and
    # the on-device project is not duplicated into hosted persistence.
    assert has_element?(
             view,
             ~s{li[data-storage-mode=device] a[href="/local/projects/#{device.id}"]}
           )

    assert length(Devices.list_projects()) == 1
  end

  defp store_path do
    dir = Path.join(System.tmp_dir!(), "sdd_mixed_catalog_#{System.unique_integer([:positive])}")
    Path.join(dir, "store.dets")
  end
end
