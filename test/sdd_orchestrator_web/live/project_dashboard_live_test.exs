defmodule SddOrchestratorWeb.ProjectDashboardLiveTest do
  @moduledoc """
  Proof for the project dashboard (Task 8): it shows the linked repository, storage
  mode, and connection status; renames inline through the reusable rename operation
  with case-insensitive conflict feedback and stable identity; keeps a project
  visible with a disconnected indicator and a recovery action when access is lost;
  never exposes the access token; and refuses unknown or cross-workspace projects
  behind a valid session.

  It also proves `specs/45` Task 2: the screen acts as the account the resolved
  acting identity names, so the passwordless email link opens the projects that
  account owns, the GitHub session is unchanged, and workspace scoping is still
  the only authorization on either session.
  """
  use SddOrchestratorWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias SddOrchestrator.Accounts
  alias SddOrchestrator.AccountsFixtures
  alias SddOrchestrator.HostedAccess.SessionCookie
  alias SddOrchestrator.HostedAccessFixtures
  alias SddOrchestrator.Projects
  alias SddOrchestrator.Projects.RepositoryConnection
  alias SddOrchestrator.ProjectsFixtures
  alias SddOrchestrator.Repo

  # Logs in an account whose login drives the given fake-provider scenario.
  defp log_in_scenario(conn, login) do
    %{conn: conn, account: account} = register_and_log_in_account(%{conn: conn, login: login})
    workspace = ProjectsFixtures.workspace_fixture(account)
    %{conn: conn, account: account, workspace: workspace}
  end

  # Signs the browser in through the passwordless email link only. No
  # application session is issued, so the screen sees the hosted credential
  # alone.
  defp hosted_scenario(conn) do
    hosted = HostedAccessFixtures.verified_hosted_session_fixture()

    conn =
      init_test_session(conn, %{SessionCookie.session_key() => hosted.session_cookie.value})

    %{conn: conn, account: hosted.account, workspace: hosted.personal_workspace}
  end

  # The kind of project a passwordless owner can actually create: hosted
  # storage, a local repository, and a machine bound at registration. It has no
  # `RepositoryConnection` row at all.
  defp hosted_local_project(workspace, name) do
    device = ProjectsFixtures.device_workspace_fixture()
    attempt = ProjectsFixtures.device_attempt_ready_for_hosted(device, workspace)
    {:ok, project} = Projects.register_project(workspace, attempt, name: name)
    project
  end

  describe "connected project (AC-30)" do
    test "shows the repository, storage mode, and connected status", %{conn: conn} do
      %{conn: conn, workspace: workspace} = log_in_scenario(conn, "octo")
      project = ProjectsFixtures.registered_project(workspace, name: "Roadmap")

      {:ok, _view, html} = live(conn, ~p"/projects/#{project.id}/overview")

      assert html =~ ~s(data-screen="project-dashboard")
      assert html =~ "Roadmap"
      assert html =~ "octo/example"
      assert html =~ "In my SDD Orchestrator account"
      assert html =~ "Connected"
    end

    test "does not expose the GitHub access token in the payload", %{conn: conn} do
      %{conn: conn, account: account, workspace: workspace} = log_in_scenario(conn, "octo")
      project = ProjectsFixtures.registered_project(workspace, name: "Roadmap")

      {:ok, _view, html} = live(conn, ~p"/projects/#{project.id}/overview")
      credential = Accounts.get_github_credential(account.id)

      refute html =~ credential.access_token
    end
  end

  describe "rename control (AC-36)" do
    test "saves a valid new name inline and keeps identity stable", %{conn: conn} do
      %{conn: conn, workspace: workspace} = log_in_scenario(conn, "octo")
      project = ProjectsFixtures.registered_project(workspace, name: "Original")
      repo_id = project.repository_connection.provider_repository_id

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/overview")

      html =
        view |> form("#project-rename-form", project: %{name: "Renamed"}) |> render_submit()

      assert html =~ "Saved"
      assert html =~ "Renamed"

      reloaded = Repo.get_by!(RepositoryConnection, project_id: project.id)
      assert reloaded.provider_repository_id == repo_id
    end

    test "shows inline feedback for a case-insensitive conflict", %{conn: conn} do
      %{conn: conn, workspace: workspace} = log_in_scenario(conn, "octo")

      ProjectsFixtures.registered_project(workspace,
        name: "Taken",
        repository: ProjectsFixtures.repository_metadata(id: 1)
      )

      project =
        ProjectsFixtures.registered_project(workspace,
          name: "Movable",
          repository: ProjectsFixtures.repository_metadata(id: 2)
        )

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/overview")

      html = view |> form("#project-rename-form", project: %{name: "taken"}) |> render_submit()

      assert html =~ "already been taken"
      # The project keeps its original name.
      assert Repo.get!(SddOrchestrator.Projects.Project, project.id).name == "Movable"
    end
  end

  describe "connection recovery (AC-37/38)" do
    test "keeps a project visible with a disconnected indicator and a recovery action", %{
      conn: conn
    } do
      %{conn: conn, workspace: workspace} = log_in_scenario(conn, "noinstall-x")
      project = ProjectsFixtures.registered_project(workspace, name: "Orphaned")

      {:ok, _view, html} = live(conn, ~p"/projects/#{project.id}/overview")

      assert html =~ "Orphaned"
      assert html =~ "Disconnected"
      assert html =~ "data-disconnected"
      assert html =~ "Check again"
    end

    test "Check again re-runs the revalidation", %{conn: conn} do
      %{conn: conn, workspace: workspace} = log_in_scenario(conn, "noinstall-x")
      project = ProjectsFixtures.registered_project(workspace, name: "Orphaned")

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/overview")

      html = view |> element("button[data-recheck]") |> render_click()
      # Access is still unavailable in this scenario, so it stays disconnected.
      assert html =~ "Disconnected"
    end
  end

  describe "routing and access" do
    setup %{conn: conn} do
      %{conn: conn, account: account} = register_and_log_in_account(%{conn: conn})
      %{conn: conn, workspace: ProjectsFixtures.workspace_fixture(account)}
    end

    test "routes an unknown project id back to the catalog", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/projects"}}} =
               live(conn, ~p"/projects/#{Ecto.UUID.generate()}/overview")
    end

    test "never resolves another workspace's project", %{conn: conn} do
      foreign = ProjectsFixtures.workspace_fixture(AccountsFixtures.account_fixture())
      foreign_project = ProjectsFixtures.registered_project(foreign, name: "Theirs")

      assert {:error, {:live_redirect, %{to: "/projects"}}} =
               live(conn, ~p"/projects/#{foreign_project.id}/overview")
    end
  end

  describe "project navigation (AC-48)" do
    test "marks the overview as current and offers the project's other screens", %{conn: conn} do
      %{conn: conn, workspace: workspace} = log_in_scenario(conn, "octo")
      project = ProjectsFixtures.registered_project(workspace, name: "Roadmap")

      {:ok, view, html} = live(conn, ~p"/projects/#{project.id}/overview")

      assert has_element?(view, "nav[aria-label='Project'][data-project-nav]")
      assert has_element?(view, ~s([data-nav-destination="overview"][data-nav-current]))
      assert has_element?(view, ~s([data-nav-destination="overview"][aria-current="page"]))

      assert has_element?(
               view,
               ~s([data-nav-destination="features"][href="/projects/#{project.id}/features"])
             )

      assert has_element?(
               view,
               ~s([data-nav-destination="people"][href="/projects/#{project.id}/participation"])
             )

      refute has_element?(view, ~s([data-nav-destination="features"][data-nav-current]))

      # The `People` top-bar button the navigation replaced is gone; `Projects`
      # and `Sign out` are not project navigation and stay.
      assert count(html, ~s(href="/projects/#{project.id}/participation")) == 1
      assert has_element?(view, ~s(a[href="/projects"]))
      assert has_element?(view, ~s(a[href="/auth/sign_out"]))
    end

    test "builds every destination from this project only", %{conn: conn} do
      %{conn: conn, workspace: workspace} = log_in_scenario(conn, "octo")
      project = ProjectsFixtures.registered_project(workspace, name: "Roadmap")

      foreign = ProjectsFixtures.workspace_fixture(AccountsFixtures.account_fixture())
      foreign_project = ProjectsFixtures.registered_project(foreign, name: "Theirs")

      {:ok, view, html} = live(conn, ~p"/projects/#{project.id}/overview")

      refute html =~ foreign_project.id

      hrefs =
        view
        |> element("[data-project-nav]")
        |> render()
        |> then(&Regex.scan(~r/href="([^"]+)"/, &1, capture: :all_but_first))
        |> List.flatten()

      assert length(hrefs) == 4
      assert Enum.all?(hrefs, &String.starts_with?(&1, "/projects/#{project.id}/"))
    end
  end

  describe "hosted session access (AC-01)" do
    test "opens the account's own hosted local-repository project", %{conn: conn} do
      %{conn: conn, workspace: workspace} = hosted_scenario(conn)
      project = hosted_local_project(workspace, "Ledger")

      {:ok, _view, html} = live(conn, ~p"/projects/#{project.id}/overview")

      assert html =~ ~s(data-screen="project-dashboard")
      assert html =~ "Ledger"
      assert html =~ "Repository"
      assert html =~ "In my SDD Orchestrator account"
      assert html =~ ~s(data-worker-connection="connected")
      assert html =~ "Connected to your machine"
    end

    test "revalidation is a no-op for an account with no GitHub credential", %{conn: conn} do
      %{conn: conn, account: account, workspace: workspace} = hosted_scenario(conn)
      project = hosted_local_project(workspace, "Ledger")

      # The account has no GitHub credential, so a revalidation that actually
      # ran would resolve to confirmed access loss.
      assert {:error, _reason} = Accounts.valid_access_token(account.id)

      # The connected mount revalidates. Nothing about the machine link is
      # reported as lost, and no connection row is invented to carry a status.
      {:ok, view, html} = live(conn, ~p"/projects/#{project.id}/overview")
      assert html =~ ~s(data-worker-connection="connected")
      assert Repo.aggregate(RepositoryConnection, :count) == 0

      # `Check again` revalidates a second time with the same result.
      rechecked = view |> element("button[data-recheck]") |> render_click()
      assert rechecked =~ ~s(data-worker-connection="connected")
      assert Repo.aggregate(RepositoryConnection, :count) == 0
    end

    test "the same project opens unchanged on an application session", %{conn: conn} do
      %{conn: conn, workspace: workspace} = log_in_scenario(conn, "octo")
      project = hosted_local_project(workspace, "Ledger")

      {:ok, _view, html} = live(conn, ~p"/projects/#{project.id}/overview")

      assert html =~ ~s(data-screen="project-dashboard")
      assert html =~ "Ledger"
      assert html =~ "In my SDD Orchestrator account"
      assert html =~ ~s(data-worker-connection="connected")
    end
  end

  describe "another account's project (AC-07)" do
    test "is not found on a hosted session and discloses nothing", %{conn: conn} do
      %{conn: conn} = hosted_scenario(conn)
      foreign = ProjectsFixtures.workspace_fixture(AccountsFixtures.account_fixture())
      foreign_project = hosted_local_project(foreign, "Theirs")

      assert {:error, {:live_redirect, %{to: "/projects"}}} =
               live(conn, ~p"/projects/#{foreign_project.id}/overview")
    end

    test "is not found on an application session and discloses nothing", %{conn: conn} do
      %{conn: conn} = log_in_scenario(conn, "octo")
      foreign = ProjectsFixtures.workspace_fixture(AccountsFixtures.account_fixture())
      foreign_project = hosted_local_project(foreign, "Theirs")

      assert {:error, {:live_redirect, %{to: "/projects"}}} =
               live(conn, ~p"/projects/#{foreign_project.id}/overview")
    end
  end

  test "requires a session the acting identity accepts", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/?hosted_access=required"}}} =
             live(conn, ~p"/projects/#{Ecto.UUID.generate()}/overview")
  end

  defp count(html, needle), do: html |> String.split(needle) |> length() |> Kernel.-(1)
end
