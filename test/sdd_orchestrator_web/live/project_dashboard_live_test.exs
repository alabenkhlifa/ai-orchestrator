defmodule SddOrchestratorWeb.ProjectDashboardLiveTest do
  @moduledoc """
  Proof for the project-dashboard placeholder the registration transaction routes
  to (Task 7 seam for Task 8): it renders the created project's repository, storage
  mode, and connected status, refuses unknown or cross-workspace project ids, and
  requires an authenticated session. The full dashboard, rename control, and
  connection recovery replace this placeholder in Task 8.
  """
  use SddOrchestratorWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias SddOrchestrator.AccountsFixtures
  alias SddOrchestrator.ProjectsFixtures

  describe "authenticated" do
    setup %{conn: conn} do
      %{conn: conn, account: account} = register_and_log_in_account(%{conn: conn})
      workspace = ProjectsFixtures.workspace_fixture(account)
      %{conn: conn, workspace: workspace}
    end

    test "shows the repository, storage mode, and connected status", %{
      conn: conn,
      workspace: workspace
    } do
      project = ProjectsFixtures.registered_project(workspace, name: "Roadmap")

      {:ok, _view, html} = live(conn, ~p"/projects/#{project.id}")

      assert html =~ ~s(data-screen="project-dashboard")
      assert html =~ "Roadmap"
      assert html =~ "octo/example"
      assert html =~ "In my SDD Orchestrator account"
      assert html =~ "Connected"
    end

    test "routes an unknown project id back to the catalog", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/projects"}}} =
               live(conn, ~p"/projects/#{Ecto.UUID.generate()}")
    end

    test "never resolves another workspace's project", %{conn: conn} do
      foreign = ProjectsFixtures.workspace_fixture(AccountsFixtures.account_fixture())
      foreign_project = ProjectsFixtures.registered_project(foreign, name: "Theirs")

      assert {:error, {:live_redirect, %{to: "/projects"}}} =
               live(conn, ~p"/projects/#{foreign_project.id}")
    end
  end

  test "requires an authenticated session", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} =
             live(conn, ~p"/projects/#{Ecto.UUID.generate()}")
  end
end
