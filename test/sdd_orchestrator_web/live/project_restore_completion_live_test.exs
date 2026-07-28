defmodule SddOrchestratorWeb.ProjectRestoreCompletionLiveTest do
  @moduledoc """
  Task 15 proof for restore conflict recovery, atomic completion, and explicit
  repository reconnection handoff.
  """

  use SddOrchestratorWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias SddOrchestrator.AccountsFixtures
  alias SddOrchestrator.Devices.DeviceStore.Local

  alias SddOrchestrator.Portability.{
    BackupSnapshot,
    ImportAttempt,
    PackageEncryption,
    PackageProvenance
  }

  alias SddOrchestrator.Projects.{Project, RepositoryConnection}
  alias SddOrchestrator.ProjectsFixtures
  alias SddOrchestrator.Repo

  setup do
    path = store_path()
    on_exit(fn -> File.rm_rf!(Path.dirname(path)) end)
    start_supervised!({Local, path: path})
    :ok
  end

  test "restores atomically with stable identity and an explicit reconnection handoff", %{
    conn: conn
  } do
    passphrase = "completion phrase"

    %{encrypted: encrypted, project_id: project_id, project_name: project_name} =
      lost_source_backup("Restored payments", 7_101, passphrase)

    %{conn: conn, account: destination_account} = register_and_log_in_account(%{conn: conn})
    destination = ProjectsFixtures.workspace_fixture(destination_account)

    {:ok, view, _html} = live(conn, ~p"/restore")
    validate_package(view, "hosted", encrypted, passphrase)

    assert Repo.get(Project, project_id) == nil
    assert Repo.aggregate(ImportAttempt, :count) == 1

    view
    |> form("#project-restore-confirm-form", restore: %{passphrase: passphrase})
    |> render_submit()

    html = render_async(view, 2_000)
    assert html =~ "Project restored"
    assert html =~ project_name
    assert has_element?(view, "[data-restore-complete]")

    restored = Repo.get!(Project, project_id)
    assert restored.name == project_name
    assert restored.workspace_id == destination.id
    assert restored.canonical_repository_id == "7101"
    assert Repo.get_by!(PackageProvenance, project_id: project_id)
    assert Repo.aggregate(RepositoryConnection, :count) == 0
    assert Repo.aggregate(ImportAttempt, :count) == 0

    assert has_element?(
             view,
             "[data-reconnect-repository][data-reconnection-method=github_authorization]"
           )

    assert has_element?(view, "[data-reconnect-repository][href='/projects/#{project_id}']")
    assert html =~ "Repository source and authorization aren&#39;t included"
    refute html =~ "Create a copy"
    refute html =~ "Share with"
    refute html =~ "another user"
  end

  test "same stable identity blocks overwrite, merge, update, and rename", %{conn: conn} do
    %{conn: conn, account: account} = register_and_log_in_account(%{conn: conn})
    workspace = ProjectsFixtures.workspace_fixture(account)

    existing =
      ProjectsFixtures.registered_project(workspace,
        name: "Existing project",
        repository: ProjectsFixtures.repository_metadata(id: 7_102)
      )

    passphrase = "identity conflict phrase"
    encrypted = encrypted_backup(workspace, existing, passphrase)
    before = Repo.get!(Project, existing.id)

    {:ok, view, _html} = live(conn, ~p"/restore")
    validate_package(view, "hosted", encrypted, passphrase)

    view
    |> form("#project-restore-confirm-form", restore: %{passphrase: passphrase})
    |> render_submit()

    html = render_async(view, 2_000)
    assert has_element?(view, "[data-restore-blocked][data-conflict-type=same_identity]")
    assert html =~ "This project already exists"
    assert html =~ "can&#39;t be overwritten, merged, updated, or renamed"
    refute has_element?(view, "[data-name-conflict]")
    refute has_element?(view, "[data-reconnect-repository]")
    assert Repo.get!(Project, existing.id) == before
    assert Repo.aggregate(Project, :count) == 1
    assert Repo.aggregate(ImportAttempt, :count) == 0
  end

  test "repository conflict takes precedence and offers no relink or alternate repository", %{
    conn: conn
  } do
    passphrase = "repository conflict phrase"

    %{encrypted: encrypted} =
      lost_source_backup("Repository collision", 7_103, passphrase)

    %{conn: conn, account: destination_account} = register_and_log_in_account(%{conn: conn})
    destination = ProjectsFixtures.workspace_fixture(destination_account)

    existing =
      ProjectsFixtures.registered_project(destination,
        name: "repository COLLISION",
        repository: ProjectsFixtures.repository_metadata(id: 7_103)
      )

    before = Repo.get!(Project, existing.id)

    {:ok, view, _html} = live(conn, ~p"/restore")
    validate_package(view, "hosted", encrypted, passphrase)

    view
    |> form("#project-restore-confirm-form", restore: %{passphrase: passphrase})
    |> render_submit()

    html = render_async(view, 2_000)
    assert has_element?(view, "[data-restore-blocked][data-conflict-type=repository]")
    assert html =~ "repository is already linked to another project"
    assert html =~ "identity can&#39;t be changed"
    refute has_element?(view, "[data-name-conflict]")
    refute html =~ "Choose a different repository"
    refute html =~ "Relink"
    assert Repo.get!(Project, existing.id) == before
    assert Repo.aggregate(Project, :count) == 1
    assert Repo.aggregate(ImportAttempt, :count) == 0
  end

  test "name-only conflict requires an explicit valid available name", %{conn: conn} do
    passphrase = "name conflict phrase"

    %{
      encrypted: encrypted,
      project_id: project_id
    } = lost_source_backup("Roadmap", 7_104, passphrase)

    %{conn: conn, account: destination_account} = register_and_log_in_account(%{conn: conn})
    destination = ProjectsFixtures.workspace_fixture(destination_account)
    _name_conflict = ProjectsFixtures.project_fixture(destination, %{name: "roadmap"})
    _repeat_conflict = ProjectsFixtures.project_fixture(destination, %{name: "Delivery plan"})
    initial_count = Repo.aggregate(Project, :count)

    {:ok, view, _html} = live(conn, ~p"/restore")
    validate_package(view, "hosted", encrypted, passphrase)

    view
    |> form("#project-restore-confirm-form", restore: %{passphrase: passphrase})
    |> render_submit()

    html = render_async(view, 2_000)
    assert has_element?(view, "[data-name-conflict]")
    assert html =~ "packaged project name is already in use"
    assert Repo.get(Project, project_id) == nil

    view
    |> form("#restore-name-conflict-form",
      restore: %{name: " \n ", passphrase: passphrase}
    )
    |> render_submit()

    html = render_async(view, 2_000)
    assert html =~ "Project name can&#39;t be blank"
    assert Repo.get(Project, project_id) == nil

    view
    |> form("#restore-name-conflict-form",
      restore: %{name: "delivery PLAN", passphrase: passphrase}
    )
    |> render_submit()

    html = render_async(view, 2_000)
    assert html =~ "project name is already in use"
    assert Repo.get(Project, project_id) == nil

    view
    |> form("#restore-name-conflict-form",
      restore: %{name: "Payments restored", passphrase: passphrase}
    )
    |> render_submit()

    html = render_async(view, 2_000)
    assert html =~ "Project restored"
    assert html =~ "Payments restored"
    restored = Repo.get!(Project, project_id)
    assert restored.name == "Payments restored"
    assert Repo.aggregate(Project, :count) == initial_count + 1
    assert Repo.aggregate(ImportAttempt, :count) == 0
  end

  test "cancel from name recovery removes the attempt and returns without mutation", %{conn: conn} do
    passphrase = "cancel name phrase"

    %{encrypted: encrypted, project_id: project_id} =
      lost_source_backup("Cancel roadmap", 7_105, passphrase)

    %{conn: conn, account: destination_account} = register_and_log_in_account(%{conn: conn})
    destination = ProjectsFixtures.workspace_fixture(destination_account)
    _conflict = ProjectsFixtures.project_fixture(destination, %{name: "cancel ROADMAP"})
    initial_count = Repo.aggregate(Project, :count)

    {:ok, view, _html} = live(conn, ~p"/restore")
    validate_package(view, "hosted", encrypted, passphrase)

    view
    |> form("#project-restore-confirm-form", restore: %{passphrase: passphrase})
    |> render_submit()

    render_async(view, 2_000)
    assert has_element?(view, "[data-name-conflict]")
    assert Repo.aggregate(ImportAttempt, :count) == 1

    assert {:error, {:live_redirect, %{to: "/projects"}}} =
             view
             |> element("#restore-name-conflict-form [data-cancel-restore]")
             |> render_click()

    assert Repo.get(Project, project_id) == nil
    assert Repo.aggregate(Project, :count) == initial_count
    assert Repo.aggregate(ImportAttempt, :count) == 0
  end

  defp validate_package(view, destination, encrypted, passphrase) do
    view |> element("#restore-#{destination}") |> render_click()
    upload(view, encrypted)

    view
    |> form("#project-restore-form", restore: %{passphrase: passphrase})
    |> render_submit()

    html = render_async(view, 2_000)
    assert html =~ "This package is compatible"
    assert html =~ "No project has been"
    html
  end

  defp lost_source_backup(name, repository_id, passphrase) do
    source_account = AccountsFixtures.account_fixture()
    source_workspace = ProjectsFixtures.workspace_fixture(source_account)

    source =
      ProjectsFixtures.registered_project(source_workspace,
        name: name,
        repository: ProjectsFixtures.repository_metadata(id: repository_id)
      )

    encrypted = encrypted_backup(source_workspace, source, passphrase)
    result = %{encrypted: encrypted, project_id: source.id, project_name: source.name}
    Repo.delete!(source)
    result
  end

  defp encrypted_backup(authority, project, passphrase) do
    {:ok, package} = BackupSnapshot.build(authority, project.id)
    {:ok, encrypted} = PackageEncryption.encrypt(package, passphrase)
    encrypted
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

  defp store_path do
    dir =
      Path.join(
        System.tmp_dir!(),
        "sdd_restore_completion_#{System.unique_integer([:positive])}"
      )

    Path.join(dir, "store.dets")
  end
end
