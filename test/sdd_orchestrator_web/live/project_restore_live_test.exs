defmodule SddOrchestratorWeb.ProjectRestoreLiveTest do
  @moduledoc """
  Task 14 proof for encrypted upload, passphrase control, hosted and device
  destination authorization, asynchronous compatibility and safety validation,
  cancellation, actionable results, and absence of project mutation.
  """

  use SddOrchestratorWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias SddOrchestrator.Accounts
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.{DeviceStore.Local, Pairing}
  alias SddOrchestrator.Portability.{BackupSnapshot, ImportAttempt, PackageCodec}
  alias SddOrchestrator.Portability.PackageEncryption
  alias SddOrchestrator.Projects.Project
  alias SddOrchestrator.ProjectsFixtures
  alias SddOrchestrator.Repo

  setup do
    path = store_path()
    on_exit(fn -> File.rm_rf!(Path.dirname(path)) end)
    start_supervised!({Local, path: path})
    :ok
  end

  test "shows both destinations with normal setup handoffs when signed out", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/restore")

    assert has_element?(view, ~s([data-screen="project-restore"]))
    assert has_element?(view, "#restore-hosted[disabled]")
    assert has_element?(view, "#restore-device[disabled]")
    assert has_element?(view, "[data-setup-hosted][href*='/hosted/access']")
    assert has_element?(view, "[data-setup-device][href='/onboarding/local']")
    assert html =~ "Validation doesn&#39;t create or change a project."
  end

  test "validates a compatible hosted package asynchronously without creating a project", %{
    conn: conn
  } do
    %{conn: conn, account: account} = register_and_log_in_account(%{conn: conn})
    workspace = ProjectsFixtures.workspace_fixture(account)
    source = ProjectsFixtures.registered_project(workspace, name: "Hosted source")
    encrypted = encrypted_backup(workspace, source, "hosted restore phrase")
    initial_projects = Repo.aggregate(Project, :count)

    {:ok, view, _html} = live(conn, ~p"/restore")
    view |> element("#restore-hosted") |> render_click()
    upload(view, encrypted)

    html =
      view
      |> form("#project-restore-form", restore: %{passphrase: "hosted restore phrase"})
      |> render_submit()

    assert html =~ "Validating package compatibility and safety"
    html = render_async(view, 2_000)

    assert html =~ "This package is compatible"
    assert html =~ "No project has been"
    assert Repo.aggregate(Project, :count) == initial_projects
    assert Repo.aggregate(ImportAttempt, :count) == 1
  end

  test "validates a compatible device package without a hosted attempt", %{conn: conn} do
    {:ok, workspace} = detected_device()

    {:ok, source} =
      Devices.register_project(%{
        name: "Device source",
        repository_fingerprint: "fp-device-restore",
        status: "connected"
      })

    encrypted = encrypted_backup(workspace, source, "device restore phrase")

    {:ok, view, _html} = live(conn, ~p"/restore")
    assert has_element?(view, "#restore-device:not([disabled])")
    view |> element("#restore-device") |> render_click()
    upload(view, encrypted)

    view
    |> form("#project-restore-form", restore: %{passphrase: "device restore phrase"})
    |> render_submit()

    assert render_async(view, 2_000) =~ "This package is compatible"
    assert Repo.aggregate(ImportAttempt, :count) == 0
    assert [^source] = Devices.list_projects()
  end

  test "requires destination, package, and passphrase with focused actionable feedback", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/restore")

    html = view |> form("#project-restore-form", restore: %{passphrase: ""}) |> render_submit()

    assert html =~ "Choose where the restored project should be saved."
    assert has_element?(view, "#restore-form-error[role=alert][tabindex='-1']")
    assert_push_event(view, "restore-form-error", %{})
  end

  test "incorrect passphrase is opaque and removes the terminal hosted attempt", %{conn: conn} do
    %{conn: conn, account: account} = register_and_log_in_account(%{conn: conn})
    workspace = ProjectsFixtures.workspace_fixture(account)
    source = ProjectsFixtures.registered_project(workspace, name: "Wrong passphrase")
    encrypted = encrypted_backup(workspace, source, "correct phrase")

    {:ok, view, _html} = live(conn, ~p"/restore")
    view |> element("#restore-hosted") |> render_click()
    upload(view, encrypted)

    view
    |> form("#project-restore-form", restore: %{passphrase: "incorrect phrase"})
    |> render_submit()

    html = render_async(view, 2_000)
    assert html =~ "package or recovery passphrase couldn&#39;t be verified"
    assert_push_event(view, "restore-form-error", %{})
    assert Repo.aggregate(ImportAttempt, :count) == 0
  end

  test "reports unsupported and malformed packages without project mutation", %{conn: conn} do
    %{conn: conn, account: account} = register_and_log_in_account(%{conn: conn})
    workspace = Accounts.get_or_create_personal_workspace(account)
    source = ProjectsFixtures.registered_project(workspace, name: "Unsupported")
    encrypted = encrypted_backup(workspace, source, "version phrase")
    {:ok, envelope, body} = PackageCodec.unframe(encrypted)
    {:ok, unsupported} = envelope |> Map.put("format_version", 2) |> PackageCodec.frame(body)
    initial_projects = Repo.aggregate(Project, :count)

    {:ok, view, _html} = live(conn, ~p"/restore")
    view |> element("#restore-hosted") |> render_click()
    upload(view, unsupported)

    view
    |> form("#project-restore-form", restore: %{passphrase: "version phrase"})
    |> render_submit()

    assert render_async(view, 2_000) =~ "backup version isn&#39;t supported"
    assert Repo.aggregate(ImportAttempt, :count) == 0
    assert Repo.aggregate(Project, :count) == initial_projects
  end

  test "cancel deletes a validated attempt and returns to the owning flow", %{conn: conn} do
    %{conn: conn, account: account} = register_and_log_in_account(%{conn: conn})
    workspace = ProjectsFixtures.workspace_fixture(account)
    source = ProjectsFixtures.registered_project(workspace, name: "Cancel")
    encrypted = encrypted_backup(workspace, source, "cancel phrase")

    {:ok, view, _html} = live(conn, ~p"/restore")
    view |> element("#restore-hosted") |> render_click()
    upload(view, encrypted)

    view
    |> form("#project-restore-form", restore: %{passphrase: "cancel phrase"})
    |> render_submit()

    assert render_async(view, 2_000) =~ "This package is compatible"
    assert Repo.aggregate(ImportAttempt, :count) == 1

    assert {:error, {:live_redirect, %{to: "/projects"}}} =
             view |> element("main [data-cancel-restore]") |> render_click()

    assert Repo.aggregate(ImportAttempt, :count) == 0
  end

  defp upload(view, contents) do
    input =
      file_input(view, "#project-restore-form", :package, [
        %{
          last_modified: 1_700_000_000_000,
          name: "project.sddbackup",
          content: contents,
          size: byte_size(contents),
          type: "application/octet-stream"
        }
      ])

    render_upload(input, "project.sddbackup")
  end

  defp detected_device do
    {:ok, workspace} = Devices.establish_workspace()
    {:ok, %{code: code}} = Pairing.start_pairing(workspace.id)

    {:ok, %{worker: worker}} =
      Pairing.complete_pairing(code, %{
        os_family: "macos",
        os_major: "15",
        protocol_version: "1"
      })

    {:ok, _worker} = Pairing.mark_seen(worker)
    {:ok, workspace}
  end

  defp encrypted_backup(authority, project, passphrase) do
    {:ok, package} = BackupSnapshot.build(authority, project.id)
    {:ok, encrypted} = PackageEncryption.encrypt(package, passphrase)
    encrypted
  end

  defp store_path do
    dir = Path.join(System.tmp_dir!(), "sdd_restore_live_#{System.unique_integer([:positive])}")
    Path.join(dir, "store.dets")
  end
end
