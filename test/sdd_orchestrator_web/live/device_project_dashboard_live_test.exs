defmodule SddOrchestratorWeb.DeviceProjectDashboardLiveTest do
  @moduledoc """
  Task 7 proof: the accountless on-device project dashboard shows the linked
  repository, the `On this device` storage mode, and a connection status derived
  live from worker availability. A worker that stops moves the project to an
  unavailable state without hiding it, `Locate repository` recovery is offered, the
  project-portability recovery limit is mentioned, and an unknown project routes
  back to local onboarding.

  The device store is a singleton GenServer not started in test, so each test
  starts its own isolated instance on a unique path in an `async: false` case.
  """
  use SddOrchestratorWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.DeviceStore.Local
  alias SddOrchestrator.Devices.Pairing

  setup do
    path = store_path()
    on_exit(fn -> File.rm_rf!(Path.dirname(path)) end)
    start_supervised!({Local, path: path})
    {:ok, workspace} = Devices.establish_workspace()

    {:ok, project} =
      Devices.register_project(%{
        name: "Ledger",
        repository_fingerprint: legacy_identity(),
        status: "connected"
      })

    %{workspace: workspace, project: project}
  end

  test "shows repository, on-device storage, and a connected status when the worker is up", %{
    conn: conn,
    workspace: ws,
    project: project
  } do
    ws.id |> pair() |> seen_now()

    {:ok, view, html} = live(conn, ~p"/local/projects/#{project.id}")

    assert has_element?(view, "[data-project-name]", "Ledger")
    assert has_element?(view, "[data-connection-status=connected]")
    assert has_element?(view, "[data-storage-mode]", "On this device")
    assert has_element?(view, "[data-repository]")
    assert has_element?(view, "[data-locate-repository]")
    assert has_element?(view, "[data-backup-readiness=upgrade_required]")
    assert has_element?(view, "[data-upgrade-repository-identity]")
    assert html =~ "project portability"
  end

  test "shows backup-ready handoff for a portable identity", %{conn: conn} do
    {:ok, project} =
      Devices.register_project(%{
        name: "Portable",
        repository_fingerprint: portable_identity(),
        status: "connected"
      })

    {:ok, view, _html} = live(conn, ~p"/local/projects/#{project.id}")

    assert has_element?(view, "[data-backup-readiness=backup_ready]")
    refute has_element?(view, "[data-upgrade-repository-identity]")
    assert render(view) =~ "Repository identity ready for export"
  end

  test "shows an unavailable status and keeps the project when the worker is not running", %{
    conn: conn,
    workspace: ws,
    project: project
  } do
    # A paired-but-never-seen worker is unavailable.
    _ = pair(ws.id)

    {:ok, view, _html} = live(conn, ~p"/local/projects/#{project.id}")

    assert has_element?(view, "[data-project-name]", "Ledger")
    assert has_element?(view, "[data-connection-status=unavailable]")
    assert has_element?(view, "[data-connection-notice]")
    # The project stays visible with recovery available.
    assert has_element?(view, "[data-locate-repository]")
  end

  test "shows an authorization-required status with no worker paired", %{
    conn: conn,
    project: project
  } do
    {:ok, view, _html} = live(conn, ~p"/local/projects/#{project.id}")
    assert has_element?(view, "[data-connection-status=authorization_required]")
    assert has_element?(view, "[data-connection-notice]")
  end

  test "re-checks the connection on demand", %{conn: conn, workspace: ws, project: project} do
    worker = pair(ws.id)
    {:ok, view, _html} = live(conn, ~p"/local/projects/#{project.id}")
    assert has_element?(view, "[data-connection-status=unavailable]")

    seen_now(worker)
    render_click(view, "recheck")
    assert has_element?(view, "[data-connection-status=connected]")
  end

  test "offers Locate repository recovery pointing at onboarding in locate mode", %{
    conn: conn,
    workspace: ws,
    project: project
  } do
    ws.id |> pair() |> seen_now()
    {:ok, view, _html} = live(conn, ~p"/local/projects/#{project.id}")

    assert view
           |> element("[data-locate-repository]")
           |> render() =~ "/onboarding/local?locate=#{project.id}"
  end

  test "an unknown project routes back to local onboarding", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/onboarding/local"}}} =
             live(conn, ~p"/local/projects/#{Ecto.UUID.generate()}")
  end

  # ---- helpers ----

  defp pair(workspace_id) do
    {:ok, %{code: code}} = Pairing.start_pairing(workspace_id)

    {:ok, %{worker: worker}} =
      Pairing.complete_pairing(code, %{os_family: "macos", os_major: "15", protocol_version: "1"})

    worker
  end

  defp seen_now(worker) do
    {:ok, seen} = Pairing.mark_seen(worker)
    seen
  end

  defp store_path do
    dir = Path.join(System.tmp_dir!(), "sdd_device_dash_#{System.unique_integer([:positive])}")
    Path.join(dir, "store.dets")
  end

  defp legacy_identity do
    :crypto.mac(:hmac, :sha256, "workspace", "root")
    |> Base.url_encode64(padding: false)
  end

  defp portable_identity do
    salt = Base.url_encode64(:binary.copy(<<1>>, 32), padding: false)
    digest = Base.url_encode64(:binary.copy(<<2>>, 32), padding: false)
    "local-repo:v1:#{salt}:#{digest}"
  end
end
