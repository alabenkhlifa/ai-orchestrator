defmodule SddOrchestratorWeb.RepositoryAccessLiveTest do
  @moduledoc """
  Proof for the repository-access and picker surface. Scenarios are driven by the
  deterministic fake provider through the login carried in the account's access
  token. Covers the grant screen, pending organization approval and `Check
  again`, the searchable single-selection picker with owner/visibility/org
  metadata, empty and distinct failure states, selection persistence and the
  handoff to the storage step, and that no project is created on any path.

  Keyboard navigation and focus are browser-level concerns carried by the
  integration task (Task 9); here single-selection semantics are proven through
  the select/continue events.
  """
  use SddOrchestratorWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias SddOrchestrator.AccountsFixtures
  alias SddOrchestrator.GitHubIntegration.FakeProvider
  alias SddOrchestrator.Projects
  alias SddOrchestrator.ProjectsFixtures

  # Logs in a fresh account whose login drives the fake scenario, then opens an
  # onboarding attempt and mounts the repository-access LiveView.
  defp open(conn, login, opts \\ []) do
    github_user_id = opts[:github_user_id] || System.unique_integer([:positive])
    account = AccountsFixtures.account_fixture(login: login, github_user_id: github_user_id)
    conn = log_in_account(conn, account)
    workspace = ProjectsFixtures.workspace_fixture(account)
    {:ok, attempt} = Projects.start_onboarding_attempt(workspace)
    {:ok, view, html} = live(conn, ~p"/onboarding/repository-access/#{attempt.id}")
    %{view: view, html: html, workspace: workspace, attempt: attempt, account: account}
  end

  describe "repository picker (granted access)" do
    setup %{conn: conn} do
      open(conn, "octo-picker")
    end

    test "lists every accessible repository with owner, visibility, and org metadata", %{
      view: view,
      html: html
    } do
      assert has_element?(view, "[data-screen=repository-access][data-state=picker]")
      assert html =~ "Choose a repository"

      # All four deduplicated repositories are present (shared repo appears once).
      for name <- ["example", "secret", "shared", "platform"], do: assert(html =~ name)
      assert html =~ "octo"
      assert html =~ "acme"

      # Non-color metadata cues: visibility and organization badges.
      assert html =~ "Private"
      assert html =~ "Public"
      assert html =~ "4 repositories available"
    end

    test "search narrows the list and reports a distinct no-match state", %{view: view} do
      filtered =
        view |> element("form[phx-change=search]") |> render_change(%{"query" => "platform"})

      assert filtered =~ "platform"
      refute filtered =~ "example"

      empty = view |> element("form[phx-change=search]") |> render_change(%{"query" => "zzzzz"})
      assert empty =~ "No repositories match your search"
    end

    test "continue is disabled until exactly one repository is selected", %{view: view} do
      assert has_element?(view, "button[phx-click=continue][disabled]")

      view |> element("#repository-101") |> render_click()
      assert has_element?(view, "#repository-101[aria-checked=true]")
      refute has_element?(view, "button[phx-click=continue][disabled]")
    end

    test "selecting another repository replaces the selection (single-select)", %{view: view} do
      view |> element("#repository-101") |> render_click()
      view |> element("#repository-102") |> render_click()

      assert has_element?(view, "#repository-102[aria-checked=true]")
      assert has_element?(view, "#repository-101[aria-checked=false]")
    end

    test "continue persists the selection and hands off to the storage step", %{
      view: view,
      workspace: workspace,
      attempt: attempt
    } do
      view |> element("#repository-101") |> render_click()
      view |> element("button[phx-click=continue]") |> render_click()

      assert_redirect(view, ~p"/onboarding/storage/#{attempt.id}")

      selected = Projects.get_onboarding_attempt(workspace, attempt.id).selected_repository
      assert selected["repository_id"] == 101
      assert selected["full_name"] == "octo-picker/example"
    end

    test "preselects a previously chosen repository (resumable)", %{conn: conn} do
      account = AccountsFixtures.account_fixture(login: "octo-resume")
      conn = log_in_account(conn, account)
      workspace = ProjectsFixtures.workspace_fixture(account)
      {:ok, attempt} = Projects.start_onboarding_attempt(workspace)

      {:ok, _} =
        Projects.select_repository(workspace, attempt.id, %{
          id: 101,
          owner: "octo-resume",
          name: "example",
          full_name: "octo-resume/example",
          private: false,
          visibility: "public",
          html_url: "https://github.com/octo-resume/example",
          organization: nil
        })

      {:ok, view, _html} = live(conn, ~p"/onboarding/repository-access/#{attempt.id}")
      assert has_element?(view, "#repository-101[aria-checked=true]")
    end
  end

  describe "grant screen (no installation)" do
    setup %{conn: conn} do
      open(conn, "noinstall-user")
    end

    test "shows the grant screen with Continue to GitHub and no picker", %{
      view: view,
      html: html,
      workspace: workspace
    } do
      assert has_element?(view, "[data-state=grant]")
      assert html =~ "Grant repository access"
      assert has_element?(view, "a[href*='/github/install']", "Continue to GitHub")
      refute has_element?(view, "#repository-list")

      # No project or repository connection has been created.
      refute Projects.has_projects?(workspace)
    end
  end

  describe "pending organization approval" do
    setup %{conn: conn} do
      open(conn, "pending-user", github_user_id: FakeProvider.pending_requester_github_id())
    end

    test "waits for approval and never exposes the picker on Check again", %{
      view: view,
      html: html,
      workspace: workspace
    } do
      assert has_element?(view, "[data-state=pending]")
      assert html =~ "Waiting for organization approval"

      rechecked = view |> element("button[phx-click=check_again]") |> render_click()
      # A pending request must not be treated as granted access.
      assert rechecked =~ "Waiting for organization approval"
      refute has_element?(view, "#repository-list")
      refute Projects.has_projects?(workspace)
    end
  end

  describe "empty and failure states" do
    test "distinguishes an empty repository set", %{conn: conn} do
      %{view: view, html: html} = open(conn, "norepos-user")
      assert has_element?(view, "[data-state=empty]")
      assert html =~ "No repositories available"
    end

    test "shows organization restriction distinctly", %{conn: conn} do
      %{view: view, html: html, workspace: workspace} = open(conn, "restricted-user")
      assert has_element?(view, "[data-state=error]")
      assert html =~ "Organization access is restricted"
      refute Projects.has_projects?(workspace)
    end

    test "shows a rate-limit state", %{conn: conn} do
      %{html: html} = open(conn, "ratelimit-user")
      assert html =~ "rate limiting"
    end

    test "shows an authorization-failure state", %{conn: conn} do
      %{html: html} = open(conn, "unauthorized-user")
      assert html =~ "sign-in needs refreshing"
    end

    test "shows a generic provider-failure state and creates no project", %{conn: conn} do
      %{html: html, workspace: workspace} = open(conn, "providerfail-user")
      assert html =~ "Something went wrong reaching GitHub"
      refute Projects.has_projects?(workspace)
    end
  end

  describe "attempt scoping and auth" do
    setup %{conn: conn} do
      %{conn: conn, account: account} = register_and_log_in_account(%{conn: conn})
      workspace = ProjectsFixtures.workspace_fixture(account)
      {:ok, attempt} = Projects.start_onboarding_attempt(workspace)
      %{conn: conn, account: account, workspace: workspace, attempt: attempt}
    end

    test "routes back to the catalog for an unknown attempt", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/projects"}}} =
               live(conn, ~p"/onboarding/repository-access/#{Ecto.UUID.generate()}")
    end

    test "routes back to the catalog for a malformed attempt id", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/projects"}}} =
               live(conn, ~p"/onboarding/repository-access/not-a-uuid")
    end

    test "never resolves another workspace's attempt", %{conn: conn} do
      foreign = ProjectsFixtures.workspace_fixture(AccountsFixtures.account_fixture())
      {:ok, foreign_attempt} = Projects.start_onboarding_attempt(foreign)

      assert {:error, {:live_redirect, %{to: "/projects"}}} =
               live(conn, ~p"/onboarding/repository-access/#{foreign_attempt.id}")
    end
  end

  test "requires an authenticated session", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} =
             live(conn, ~p"/onboarding/repository-access/#{Ecto.UUID.generate()}")
  end
end
