defmodule SddOrchestratorWeb.OnboardingFlowTest do
  @moduledoc """
  End-to-end integration proof for the onboarding navigation (Task 9).

  Drives the whole authenticated flow across every screen seam with the deterministic
  GitHub fake — catalog routing, repository-access check and picker, storage
  selection, confirmation and creation, and the new-project dashboard — asserting the
  navigation continuity and resumable attempt state that connect the surfaces owned by
  Tasks 3 through 8. This is the deterministic local proof; the desktop and mobile
  browser scenarios across the same flow run against a live GitHub App in the
  secret-backed staging environment (environment-blocked locally).
  """
  use SddOrchestratorWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias SddOrchestrator.Projects.Project
  alias SddOrchestrator.ProjectsFixtures
  alias SddOrchestrator.Repo

  # The "octo" login drives the fake provider's normal scenario (an installation
  # whose repositories include id 101, "octo/example").
  defp log_in(conn), do: register_and_log_in_account(%{conn: conn, login: "octo"})

  test "walks the empty-workspace flow from catalog to the new project's dashboard", %{conn: conn} do
    %{conn: conn} = log_in(conn)

    # An empty workspace continues straight to the repository-access check.
    assert {:error, {:live_redirect, %{to: access_path}}} = live(conn, ~p"/projects")
    assert "/onboarding/repository-access/" <> attempt_id = access_path

    # Repository picker (loaded via the fake): select a repo and continue to storage.
    {:ok, access_view, _html} = live(conn, access_path)
    render_click(access_view, "select", %{"id" => "101"})
    assert {:error, {:live_redirect, %{to: storage_path}}} = render_click(access_view, "continue")
    assert storage_path == "/onboarding/storage/#{attempt_id}"

    # Storage step: choose hosted and continue to confirmation. The same attempt
    # id threads through, proving resumable continuity across the seams.
    {:ok, storage_view, html} = live(conn, storage_path)
    assert html =~ "octo/example"
    render_click(storage_view, "select_mode", %{"mode" => "hosted"})

    assert {:error, {:live_redirect, %{to: confirm_path}}} =
             render_click(storage_view, "continue")

    assert confirm_path == "/onboarding/confirm/#{attempt_id}"

    # Confirmation: the default name is derived; submit creates the project and
    # routes to its dashboard.
    {:ok, confirm_view, html} = live(conn, confirm_path)
    assert html =~ "octo/example"
    assert html =~ ~s(value="example")

    assert {:error, {:redirect, %{to: dashboard_path}}} =
             confirm_view
             |> form("#project-confirmation-form", project: %{name: "example"})
             |> render_submit()

    assert "/projects/" <> _project_id = dashboard_path

    # The project's address is a landing decision. A just-created project has no
    # owner display name yet, so its feature board is not usable and the landing
    # opens the overview instead of the board (specs/07 AC-48).
    assert {:error, {:redirect, %{to: overview_path}}} = live(conn, dashboard_path)
    assert overview_path == dashboard_path <> "/overview"

    # The dashboard shows the linked repository, storage mode, and connected status.
    {:ok, _dash, html} = live(conn, overview_path)
    assert html =~ ~s(data-screen="project-dashboard")
    assert html =~ "octo/example"
    assert html =~ "In my SDD Orchestrator account"
    assert html =~ "Connected"

    assert Repo.aggregate(Project, :count) == 1
  end

  test "Add project from a non-empty catalog resumes the same flow", %{conn: conn} do
    %{conn: conn, account: account} = log_in(conn)
    workspace = ProjectsFixtures.workspace_fixture(account)
    ProjectsFixtures.registered_project(workspace, name: "Existing")

    {:ok, catalog, _html} = live(conn, ~p"/projects")

    assert {:error, {:live_redirect, %{to: access_path}}} =
             render_click(catalog, "add_project")

    assert "/onboarding/repository-access/" <> _attempt_id = access_path

    # The handoff is non-mutating: still exactly the one pre-existing project.
    assert Repo.aggregate(Project, :count) == 1
  end

  test "an interrupted flow resumes on the storage step with the repository preserved", %{
    conn: conn
  } do
    %{conn: conn, account: account} = log_in(conn)
    workspace = ProjectsFixtures.workspace_fixture(account)
    attempt = ProjectsFixtures.attempt_with_repository(workspace)

    # Returning directly to the storage step (e.g. after device setup) still shows
    # the previously selected repository — onboarding state is resumable.
    {:ok, _view, html} = live(conn, ~p"/onboarding/storage/#{attempt.id}")
    assert html =~ "octo/example"
  end
end
