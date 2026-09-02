defmodule SddOrchestratorWeb.ProjectsLiveTest do
  @moduledoc """
  Proof for the protected project catalog and its post-authentication routing:
  a restored non-empty workspace shows its catalog with `Add project`, an empty
  workspace continues to the repository-access check, `Add project` hands off
  without creating a project, and credentials never reach the payload.

  It also proves the catalog on a passwordless hosted session: the acting
  account's own projects and no others, a header with no GitHub identity chip
  and no control that leads to an application-session-only screen, an empty
  workspace rendering rather than redirecting into the GitHub repository-access
  check, and connection revalidation staying a no-op for an account with no
  GitHub credential.
  """
  use SddOrchestratorWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias SddOrchestrator.Accounts
  alias SddOrchestrator.Catalog
  alias SddOrchestrator.HostedAccess.SessionCookie
  alias SddOrchestrator.HostedAccessFixtures
  alias SddOrchestrator.Projects
  alias SddOrchestrator.Projects.{Project, ProjectOnboardingAttempt, RepositoryConnection}
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

    test "a connected project shows its badge and asks for no recheck", %{
      conn: conn,
      account: account
    } do
      workspace = ProjectsFixtures.workspace_fixture(account)
      ProjectsFixtures.registered_project(workspace, name: "Roadmap Alpha")

      {:ok, view, html} = live(conn, ~p"/projects")

      assert html =~ "Roadmap Alpha"
      assert html =~ "Connected"
      refute html =~ "Disconnected"
      refute has_element?(view, "button[data-recheck]")
    end

    test "a connection with no full name is still a connection", %{conn: conn} do
      %{conn: conn, account: account} =
        register_and_log_in_account(%{conn: conn, login: "noinstall-nolabel"})

      workspace = ProjectsFixtures.workspace_fixture(account)
      project = ProjectsFixtures.registered_project(workspace, name: "Unlabelled")

      # `full_name` is not required on a connection, so a real connection can
      # leave the row's repository label nil. Keying the GitHub presentation on
      # that label instead of on the connection would hide the badge here.
      {1, _} =
        Repo.update_all(
          from(c in RepositoryConnection, where: c.project_id == ^project.id),
          set: [full_name: nil]
        )

      {:ok, view, html} = live(conn, ~p"/projects")

      assert [entry] = Catalog.combined(account, workspace, revalidate: false)
      assert entry.repository_connection?
      refute entry.repository_label

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

  describe "the GitHub owner's catalog is unchanged (AC-06)" do
    test "keeps the identity chip, both GitHub controls, and the application sign-out", %{
      conn: conn,
      account: account
    } do
      workspace = ProjectsFixtures.workspace_fixture(account)
      ProjectsFixtures.project_fixture(workspace, name: "Roadmap Alpha")

      {:ok, view, html} = live(conn, ~p"/projects")

      assert html =~ Accounts.get_github_identity(account.id).login
      assert has_element?(view, "a[data-notifications-link]")
      assert has_element?(view, "a[data-ai-connections-link]")
      assert has_element?(view, ~s{a[href="/auth/sign_out"]})
      refute has_element?(view, ~s{a[href="/hosted/session"]})
      assert has_element?(view, "button", "Add project")
      refute has_element?(view, "[data-empty-catalog]")
    end
  end

  describe "the passwordless owner's catalog (AC-02, AC-04)" do
    setup %{account: account} do
      hosted = HostedAccessFixtures.verified_hosted_session_fixture()

      # The application account from the module setup owns the projects this
      # hosted session must not see.
      other_workspace = ProjectsFixtures.workspace_fixture(account)
      ProjectsFixtures.project_fixture(other_workspace, name: "Someone Elses Roadmap")

      %{conn: hosted_conn(hosted), hosted: hosted}
    end

    test "shows the projects the acting account owns and none from another account", %{
      conn: conn,
      hosted: hosted
    } do
      hosted_local_project(hosted, "My Local Roadmap")

      {:ok, _view, html} = live(conn, ~p"/projects")

      assert html =~ "My Local Roadmap"
      refute html =~ "Someone Elses Roadmap"
    end

    test "a local-repository row makes no GitHub claim and asks for no recheck", %{
      conn: conn,
      hosted: hosted
    } do
      hosted_local_project(hosted, "My Local Roadmap")

      {:ok, view, html} = live(conn, ~p"/projects")

      assert html =~ "My Local Roadmap"
      refute html =~ "Disconnected"
      refute html =~ "Connected"
      refute has_element?(view, "button[data-recheck]")
    end

    test "offers no GitHub identity chip, no Add project, and no GitHub-only screen", %{
      conn: conn,
      hosted: hosted
    } do
      hosted_local_project(hosted, "My Local Roadmap")

      {:ok, view, html} = live(conn, ~p"/projects")

      refute Accounts.get_github_identity(hosted.account.id)
      refute html =~ "Add project"
      refute has_element?(view, "a[data-notifications-link]")
      refute has_element?(view, "a[data-ai-connections-link]")
      refute has_element?(view, ~s{a[href="/notifications"]})
      refute has_element?(view, ~s{a[href="/ai-connections"]})
    end

    test "signs out of the hosted session rather than the application session", %{
      conn: conn,
      hosted: hosted
    } do
      hosted_local_project(hosted, "My Local Roadmap")

      {:ok, view, _html} = live(conn, ~p"/projects")

      assert has_element?(view, ~s{a[href="/hosted/session"]}, "Sign out")
      refute has_element?(view, ~s{a[href="/auth/sign_out"]})
    end

    test "an empty workspace renders the catalog with the local flow, not a redirect", %{
      conn: conn
    } do
      {:ok, view, html} = live(conn, ~p"/projects")

      assert html =~ "No projects yet"
      assert html =~ "Create one from a repository on your computer."
      assert has_element?(view, ~s{a[href="/onboarding/local"]}, "Work without GitHub")
      refute has_element?(view, "[data-project-row]")
    end

    test "a forged add_project event opens no attempt and does not navigate", %{
      conn: conn,
      hosted: hosted
    } do
      hosted_local_project(hosted, "My Local Roadmap")

      {:ok, view, _html} = live(conn, ~p"/projects")

      # The control is never rendered for this account, so the event is forged.
      assert render_click(view, "add_project") =~ "My Local Roadmap"

      assert Repo.aggregate(
               from(a in ProjectOnboardingAttempt,
                 where: a.workspace_id == ^hosted.personal_workspace.id
               ),
               :count
             ) == 0
    end

    test "an empty workspace opens no onboarding attempt", %{conn: conn, hosted: hosted} do
      {:ok, _view, _html} = live(conn, ~p"/projects")

      assert Repo.aggregate(
               from(a in ProjectOnboardingAttempt,
                 where: a.workspace_id == ^hosted.personal_workspace.id
               ),
               :count
             ) == 0
    end

    test "revalidation is a no-op for an account with no GitHub credential", %{
      conn: conn,
      hosted: hosted
    } do
      project = hosted_local_project(hosted, "My Local Roadmap")

      refute Accounts.get_github_credential(hosted.account.id)

      # A local repository gets no `RepositoryConnection`, so revalidation has
      # nothing to re-read and cannot mark anything disconnected. Proven by the
      # revalidating read matching the persisted one rather than assumed.
      assert Repo.aggregate(
               from(c in RepositoryConnection, where: c.project_id == ^project.id),
               :count
             ) == 0

      revalidated = Catalog.combined(hosted.account, hosted.personal_workspace, revalidate: true)
      persisted = Catalog.combined(hosted.account, hosted.personal_workspace, revalidate: false)

      assert revalidated == persisted
      assert [%{id: id}] = revalidated
      assert id == project.id

      # The connected mount revalidates, and it still renders the project.
      {:ok, _view, html} = live(conn, ~p"/projects")
      assert html =~ "My Local Roadmap"
    end
  end

  describe "no session at all (AC-05)" do
    test "halts to the entry surface with the hosted-access notice" do
      assert {:error, {:redirect, %{to: to}}} = live(build_conn(), ~p"/projects")
      assert to == "/?hosted_access=required"
    end
  end

  defp hosted_conn(hosted) do
    Plug.Test.init_test_session(
      build_conn(),
      %{SessionCookie.session_key() => hosted.session_cookie.value}
    )
  end

  # A hosted project whose repository is on this person's Mac: the only kind a
  # passwordless owner can create today (specs/44).
  defp hosted_local_project(hosted, name) do
    device_workspace = ProjectsFixtures.device_workspace_fixture()

    attempt =
      ProjectsFixtures.device_attempt_ready_for_hosted(
        device_workspace,
        hosted.personal_workspace
      )

    {:ok, project} =
      Projects.register_project(hosted.personal_workspace, attempt, name: name)

    project
  end
end
