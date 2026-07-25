defmodule SddOrchestratorWeb.ProjectConfirmationLiveTest do
  @moduledoc """
  LiveView proof for the final-confirmation and creation surface (Task 7): it
  reviews the selected repository, storage mode, and editable default name; creates
  the project atomically and routes to its dashboard; keeps an edited-name conflict
  inline without creating a project; reports a repository already linked with the
  existing project; and routes unknown, incomplete, consumed, or cross-workspace
  attempts correctly behind a valid session.
  """
  use SddOrchestratorWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias SddOrchestrator.AccountsFixtures
  alias SddOrchestrator.Projects
  alias SddOrchestrator.Projects.Project
  alias SddOrchestrator.ProjectsFixtures
  alias SddOrchestrator.Repo

  describe "authenticated" do
    setup %{conn: conn} do
      %{conn: conn, account: account} = register_and_log_in_account(%{conn: conn})
      workspace = ProjectsFixtures.workspace_fixture(account)
      %{conn: conn, workspace: workspace}
    end

    test "reviews the repository, storage mode, and default project name", %{
      conn: conn,
      workspace: workspace
    } do
      attempt = ProjectsFixtures.attempt_ready(workspace)

      {:ok, _view, html} = live(conn, ~p"/onboarding/confirm/#{attempt.id}")

      assert html =~ ~s(data-screen="project-confirmation")
      assert html =~ "octo/example"
      assert html =~ "In my SDD Orchestrator account"
      # The editable name field is pre-filled with the repository-derived default.
      assert html =~ ~s(value="example")
    end

    test "creates the project with the default name and routes to its dashboard", %{
      conn: conn,
      workspace: workspace
    } do
      attempt = ProjectsFixtures.attempt_ready(workspace)
      {:ok, view, _html} = live(conn, ~p"/onboarding/confirm/#{attempt.id}")

      {:error, {:live_redirect, %{to: to}}} =
        view
        |> form("form", project: %{name: "example"})
        |> render_submit()

      assert %Project{name: "example"} =
               project = Repo.get_by!(Project, workspace_id: workspace.id)

      assert to == "/projects/#{project.id}"
    end

    test "creates the project with an edited custom name", %{conn: conn, workspace: workspace} do
      attempt = ProjectsFixtures.attempt_ready(workspace)
      {:ok, view, _html} = live(conn, ~p"/onboarding/confirm/#{attempt.id}")

      view |> form("form", project: %{name: "My Roadmap"}) |> render_change()

      {:error, {:live_redirect, _}} =
        view |> form("form", project: %{name: "My Roadmap"}) |> render_submit()

      assert Repo.get_by!(Project, workspace_id: workspace.id).name == "My Roadmap"
    end

    test "an edited conflicting name shows inline feedback and creates no project", %{
      conn: conn,
      workspace: workspace
    } do
      ProjectsFixtures.project_fixture(workspace, name: "Roadmap")
      attempt = ProjectsFixtures.attempt_ready(workspace)
      {:ok, view, _html} = live(conn, ~p"/onboarding/confirm/#{attempt.id}")

      view |> form("form", project: %{name: "roadmap"}) |> render_change()
      html = view |> form("form", project: %{name: "roadmap"}) |> render_submit()

      assert html =~ "already been taken"
      # Only the pre-existing fixture project exists; no project was created here.
      assert Repo.aggregate(Project, :count) == 1
    end

    test "a repository already linked shows the existing project and blocks creation", %{
      conn: conn,
      workspace: workspace
    } do
      existing =
        ProjectsFixtures.registered_project(workspace,
          name: "First",
          repository: ProjectsFixtures.repository_metadata(id: 101)
        )

      attempt =
        ProjectsFixtures.attempt_ready(workspace,
          repository: ProjectsFixtures.repository_metadata(id: 101)
        )

      {:ok, view, _html} = live(conn, ~p"/onboarding/confirm/#{attempt.id}")

      html = view |> form("form", project: %{name: "Second"}) |> render_submit()

      assert html =~ "already linked"
      assert html =~ existing.name
      assert html =~ "/projects/#{existing.id}"
      # No second project was created.
      assert Repo.aggregate(Project, :count) == 1
    end

    test "sends an attempt without a storage mode back to the storage step", %{
      conn: conn,
      workspace: workspace
    } do
      attempt = ProjectsFixtures.attempt_with_repository(workspace)

      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, ~p"/onboarding/confirm/#{attempt.id}")

      assert to == "/onboarding/storage/#{attempt.id}"
    end

    test "routes a consumed attempt to the project it created", %{
      conn: conn,
      workspace: workspace
    } do
      attempt = ProjectsFixtures.attempt_ready(workspace)
      {:ok, project} = Projects.register_project(workspace, attempt)

      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, ~p"/onboarding/confirm/#{attempt.id}")

      assert to == "/projects/#{project.id}"
    end

    test "routes an unknown attempt back to the catalog", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/projects"}}} =
               live(conn, ~p"/onboarding/confirm/#{Ecto.UUID.generate()}")
    end

    test "never resolves another workspace's attempt", %{conn: conn} do
      foreign = ProjectsFixtures.workspace_fixture(AccountsFixtures.account_fixture())
      foreign_attempt = ProjectsFixtures.attempt_ready(foreign)

      assert {:error, {:live_redirect, %{to: "/projects"}}} =
               live(conn, ~p"/onboarding/confirm/#{foreign_attempt.id}")
    end
  end

  test "requires an authenticated session", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} =
             live(conn, ~p"/onboarding/confirm/#{Ecto.UUID.generate()}")
  end
end
