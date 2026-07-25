defmodule SddOrchestratorWeb.ProjectsLiveTest do
  @moduledoc """
  Proof for the protected project catalog and its post-authentication routing:
  a restored non-empty workspace shows its catalog with `Add project`, an empty
  workspace continues to the repository-access check, `Add project` hands off
  without creating a project, and credentials never reach the payload.
  """
  use SddOrchestratorWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias SddOrchestrator.Accounts
  alias SddOrchestrator.Projects
  alias SddOrchestrator.Projects.{Project, ProjectOnboardingAttempt}
  alias SddOrchestrator.ProjectsFixtures
  alias SddOrchestrator.Repo

  setup %{conn: conn} do
    register_and_log_in_account(%{conn: conn})
  end

  describe "restored non-empty workspace (AC-08, AC-13)" do
    test "restores the workspace and shows the catalog with visible projects", %{
      conn: conn,
      account: account
    } do
      workspace = ProjectsFixtures.workspace_fixture(account)
      ProjectsFixtures.project_fixture(workspace, name: "Roadmap Alpha")

      {:ok, _view, html} = live(conn, ~p"/projects")

      assert html =~ "Projects"
      assert html =~ "Roadmap Alpha"
      assert html =~ "Add project"
      assert html =~ "Sign out"
    end

    test "does not expose the GitHub access token in the payload", %{conn: conn, account: account} do
      workspace = ProjectsFixtures.workspace_fixture(account)
      ProjectsFixtures.project_fixture(workspace, name: "Roadmap Alpha")

      {:ok, _view, html} = live(conn, ~p"/projects")
      credential = Accounts.get_github_credential(account.id)

      refute html =~ credential.access_token
    end
  end

  describe "empty workspace continuation (AC-14)" do
    test "continues to the repository-access check without another action", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: to}}} = live(conn, ~p"/projects")
      assert to =~ ~r{^/onboarding/repository-access/}
    end

    test "opens exactly one onboarding attempt and no project", %{conn: conn, account: account} do
      assert {:error, {:live_redirect, %{to: _to}}} = live(conn, ~p"/projects")

      workspace = Accounts.get_personal_workspace(account.id)
      assert workspace

      assert Repo.aggregate(
               from(a in ProjectOnboardingAttempt, where: a.workspace_id == ^workspace.id),
               :count
             ) == 1

      assert Repo.aggregate(from(p in Project, where: p.workspace_id == ^workspace.id), :count) ==
               0
    end
  end

  describe "connection status in catalog rows (AC-37/38)" do
    test "shows a per-row connection status and a Check again recovery action", %{conn: conn} do
      # The account login drives the fake provider to report no accessible
      # installation, so the registered project's connection revalidates as lost.
      %{conn: conn, account: account} =
        register_and_log_in_account(%{conn: conn, login: "noinstall-cat"})

      workspace = ProjectsFixtures.workspace_fixture(account)
      ProjectsFixtures.registered_project(workspace, name: "Orphaned")

      {:ok, view, html} = live(conn, ~p"/projects")

      assert html =~ "Orphaned"
      assert html =~ "Disconnected"
      assert has_element?(view, "button[data-recheck]")
    end
  end

  describe "Add project handoff (AC-15)" do
    setup %{conn: conn, account: account} do
      workspace = ProjectsFixtures.workspace_fixture(account)
      ProjectsFixtures.project_fixture(workspace, name: "Existing")
      %{conn: conn, workspace: workspace}
    end

    test "hands off to the repository-access check", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/projects")

      view |> element("button", "Add project") |> render_click()

      {to, _flash} = assert_redirect(view)
      assert to =~ ~r{^/onboarding/repository-access/}
    end

    test "creates an onboarding attempt but no additional project or connection", %{
      conn: conn,
      workspace: workspace
    } do
      {:ok, view, _html} = live(conn, ~p"/projects")

      view |> element("button", "Add project") |> render_click()

      assert Repo.aggregate(
               from(a in ProjectOnboardingAttempt, where: a.workspace_id == ^workspace.id),
               :count
             ) == 1

      # The seeded project is untouched; no new project was created by the handoff.
      assert Repo.aggregate(from(p in Project, where: p.workspace_id == ^workspace.id), :count) ==
               1
    end

    test "the attempt targeted by the handoff resolves for the repository-access check", %{
      conn: conn,
      workspace: workspace
    } do
      {:ok, view, _html} = live(conn, ~p"/projects")
      view |> element("button", "Add project") |> render_click()
      {to, _flash} = assert_redirect(view)

      "/onboarding/repository-access/" <> attempt_id = to
      assert Projects.get_onboarding_attempt(workspace, attempt_id)
    end
  end
end
