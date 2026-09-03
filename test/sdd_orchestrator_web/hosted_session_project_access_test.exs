defmodule SddOrchestratorWeb.HostedSessionProjectAccessTest do
  @moduledoc """
  `specs/45` Task 5. Proof that the whole path works for a person, that a hosted
  session which is gone reaches nothing, and that no screen outside this slice's
  boundary widened.

  It owns AC-05 and AC-06:

    * AC-05 — an expired or a revoked hosted session opening the project list or
      a project screen is asked to sign in again, and no project, repository, or
      workspace data is rendered.
    * AC-06 — a person signed in with GitHub finds the project list and a project
      dashboard unchanged.

  The first scenario is the path that was impossible before this slice: creating
  a hosted project from a local repository ended at the entry surface, because
  the project screens took the application session alone. It is driven as one
  person on one browser: the local flow, the sign-in link that really arrives by
  email, and then the project and the list on the session that link issued.

  The route review is derived from `SddOrchestratorWeb.Router.__routes__/0`
  rather than written out, so a route added to an application-session live
  session later is covered without editing this file.

  The device store is a singleton GenServer not started in test, and capturing
  the delivered email needs the global Swoosh mode, so this case is `async:
  false`.
  """
  use SddOrchestratorWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import SddOrchestrator.SelectionSettling, only: [settle: 2]
  import Swoosh.TestAssertions, only: [set_swoosh_global: 1]

  alias SddOrchestrator.Accounts
  alias SddOrchestrator.Accounts.HostedSession
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.DeviceStore.Local
  alias SddOrchestrator.HostedAccess.RateLimiter
  alias SddOrchestrator.HostedAccess.SessionCookie
  alias SddOrchestrator.HostedAccess.Sessions
  alias SddOrchestrator.HostedAccessFixtures
  alias SddOrchestrator.Projects
  alias SddOrchestrator.Projects.Project
  alias SddOrchestrator.ProjectsFixtures
  alias SddOrchestrator.Repo
  alias SddOrchestratorWeb.Router
  alias SddOrchestratorWeb.UserAuth

  # The hook's own marker. Either sign-in opens these screens, so the notice it
  # asks for names no method.
  @entry_with_notice "/?project_access=required"
  @sign_in_notice "Sign in to open your projects."

  # The gate this review is about: a live session no hosted credential satisfies.
  @application_session_hook {UserAuth, :require_authenticated}

  describe "creating a hosted project and then opening it, on one hosted session" do
    setup :set_swoosh_global

    setup do
      RateLimiter.reset()

      path = store_path()
      on_exit(fn -> File.rm_rf!(Path.dirname(path)) end)
      start_supervised!({Local, path: path})
      {:ok, _workspace} = Devices.establish_workspace()

      repo = git_repo_fixture()
      on_exit(fn -> File.rm_rf!(repo) end)
      stub_folder(repo)

      %{repo: repo}
    end

    test "the person lands on the new project and finds it in their list", %{
      conn: conn,
      repo: repo
    } do
      # The accountless local flow, up to the storage question.
      {:ok, view, _html} = live(conn, ~p"/onboarding/local")

      view
      |> form("[data-pairing-form]", pairing: %{code: "4K7Q-2P9X"})
      |> render_submit()

      assert has_element?(view, "[data-worker-status=detected]")

      render_click(view, "continue_to_selection")
      render_click(view, "select_folder")
      settle(view, "data-selected-repository")
      assert has_element?(view, "[data-repository-name]", Path.basename(repo))

      render_click(view, "continue_to_storage")
      {storage_to, _flash} = assert_redirect(view)

      # Saving to an account needs a sign-in, so the step offers one and comes back.
      {:ok, storage, _html} = live(conn, storage_to)
      storage |> element("button[phx-click=setup_hosted]") |> render_click()
      {access_to, _flash} = assert_redirect(storage)
      assert access_to == ~p"/hosted/access?#{[return_to: storage_to]}"

      {:ok, access, _html} = live(conn, access_to)

      access
      |> form("#hosted-access-form", %{"email" => "ledger-owner@example.com"})
      |> render_submit()

      # The link really arrives by email, and clicking it is the sign-in. Every
      # request after this one carries the session that click issued.
      assert_receive {:email, email}
      signed_in = get(build_conn(), delivered_verification_path(email))
      assert redirected_to(signed_in) == ~p"/hosted/access/result?#{verified_return(storage_to)}"

      {:ok, result, _html} = live(signed_in, redirected_to(signed_in))
      assert has_element?(result, "#hosted-access-verified")
      # The result screen sends the person back to the step they left.
      assert has_element?(result, ~s(a[href="#{storage_to}"]), "Continue")

      # Back on the storage step, hosted is now available and gets chosen.
      {:ok, storage, _html} = live(signed_in, storage_to)
      storage |> element("#storage-hosted") |> render_click()
      storage |> element("button[phx-click=continue]") |> render_click()
      {review_to, _flash} = assert_redirect(storage)

      {:ok, review, _html} = live(signed_in, review_to)
      render_click(review, "toggle_disclosure")

      review
      |> form("[data-step=review] form", project: %{name: "Ledger Of Receipts"})
      |> render_submit()

      project = Repo.one!(Project)
      assert project.workspace_id
      {landing_to, _flash} = assert_redirect(review)
      assert landing_to == ~p"/projects/#{project.id}"

      # `/projects/:id` is a landing decision, not a screen. This project has no
      # GitHub connection, so it opens on its overview.
      landing = get(signed_in, landing_to)
      overview_to = redirected_to(landing)
      assert overview_to == ~p"/projects/#{project.id}/overview"

      # The dashboard renders rather than sending the person back to sign in.
      {:ok, _dashboard, dashboard} = live(signed_in, overview_to)
      assert dashboard =~ ~s(data-screen="project-dashboard")
      assert dashboard =~ "Ledger Of Receipts"
      assert dashboard =~ "In my SDD Orchestrator account"
      assert dashboard =~ ~s(data-worker-connection="connected")
      assert dashboard =~ "Connected to your machine"

      # And the same session finds the project in the list.
      {:ok, list_view, list} = live(signed_in, ~p"/projects")
      assert list =~ "Ledger Of Receipts"
      assert has_element?(list_view, ~s([data-project-row][data-id="#{project.id}"]))
      assert has_element?(list_view, ~s(a[href="/projects/#{project.id}"]))
    end
  end

  describe "a hosted session that is gone (AC-05)" do
    setup do
      hosted = HostedAccessFixtures.verified_hosted_session_fixture()

      %{
        hosted: hosted,
        project: hosted_local_project(hosted.personal_workspace, "Ledger Of Receipts")
      }
    end

    test "an expired session reaches neither screen and reads no project data", context do
      %{hosted: hosted, project: project} = context

      {1, _} =
        Repo.update_all(
          from(session in HostedSession, where: session.id == ^hosted.session.id),
          set: [expires_at: DateTime.utc_now() |> DateTime.add(-1, :second)]
        )

      assert_asked_to_sign_in_again(hosted, project)
    end

    test "a revoked session reaches neither screen and reads no project data", context do
      %{hosted: hosted, project: project} = context

      :ok = Sessions.revoke_current(hosted.session_cookie.value)

      assert_asked_to_sign_in_again(hosted, project)
    end
  end

  describe "the GitHub owner is unchanged (AC-06)" do
    setup %{conn: conn} do
      %{account: account} = register_and_log_in_account(%{conn: conn, login: "octo"})
      workspace = ProjectsFixtures.workspace_fixture(account)

      %{
        conn: log_in_account(build_conn(), account),
        account: account,
        project: ProjectsFixtures.registered_project(workspace, name: "Roadmap Alpha")
      }
    end

    test "the project list keeps its identity chip, GitHub controls, and sign-out", context do
      %{conn: conn, account: account, project: project} = context

      {:ok, view, html} = live(conn, ~p"/projects")

      assert html =~ "Roadmap Alpha"
      assert html =~ Accounts.get_github_identity(account.id).login
      assert has_element?(view, "a[data-notifications-link]", "Notifications")
      assert has_element?(view, "a[data-ai-connections-link]", "AI Connections")
      assert has_element?(view, "button", "Add project")

      # Sign-out still ends the application session, not a hosted one.
      assert has_element?(view, ~s(a[href="/auth/sign_out"]), "Sign out")
      refute has_element?(view, ~s(a[href="/hosted/session"]))

      # The row still names the connected GitHub repository.
      assert has_element?(view, ~s([data-project-row][data-id="#{project.id}"]))
      assert html =~ "octo/example"
      assert html =~ "Connected"
    end

    test "the project dashboard keeps its repository row, badge, and sign-out", context do
      %{conn: conn, project: project} = context

      {:ok, view, html} = live(conn, ~p"/projects/#{project.id}/overview")

      assert html =~ ~s(data-screen="project-dashboard")
      assert html =~ "Roadmap Alpha"
      assert has_element?(view, "[data-repository]", "octo/example")
      assert has_element?(view, "[data-storage-mode]", "In my SDD Orchestrator account")
      assert html =~ "Connected"
      assert has_element?(view, ~s(a[href="/auth/sign_out"]), "Sign out")
      refute has_element?(view, ~s(a[href="/hosted/session"]))
    end
  end

  describe "the route review" do
    test "every screen behind the application session still refuses a hosted-only browser" do
      hosted = HostedAccessFixtures.verified_hosted_session_fixture()
      routes = application_session_routes()
      paths = Enum.map(routes, & &1.path)

      # A derivation that silently matched nothing would pass the loop below, so
      # the set is checked for size and for screens the slice explicitly excluded.
      assert length(paths) >= 8
      assert "/ai-connections" in paths
      assert "/repository-kits" in paths
      assert "/projects/:id/backup" in paths
      assert "/notifications" in paths

      for route <- routes do
        # Every route in this set is a GET LiveView route. Asserting that rather
        # than filtering on it keeps a future non-GET route loud instead of
        # silently dropped from the review.
        assert route.verb == :get, "#{route.path} is #{route.verb}, not a GET LiveView route"

        refute String.contains?(route.path, "*"),
               "#{route.path} has a glob segment this review does not know how to drive"

        # A parameterised segment gets a well-formed id that resolves to nothing.
        # The gate halts at mount before any param is read, so refusing it is
        # still the whole proof.
        result = live(hosted_conn(hosted), concrete_path(route.path))

        assert match?({:error, {:redirect, %{to: "/"}}}, result),
               "#{route.path} did not refuse a hosted-only session, got: #{inspect(result)}"
      end
    end

    test "the two screens this slice opened accept the same hosted-only browser" do
      hosted = HostedAccessFixtures.verified_hosted_session_fixture()
      project = hosted_local_project(hosted.personal_workspace, "Ledger Of Receipts")

      # The complement is what makes the review a boundary rather than a list.
      paths = application_session_routes() |> Enum.map(& &1.path)
      refute "/projects" in paths
      refute "/projects/:id/overview" in paths

      assert {:ok, _view, list} = live(hosted_conn(hosted), ~p"/projects")
      assert list =~ "Ledger Of Receipts"

      assert {:ok, _view, dashboard} =
               live(hosted_conn(hosted), ~p"/projects/#{project.id}/overview")

      assert dashboard =~ ~s(data-screen="project-dashboard")
      assert dashboard =~ "Ledger Of Receipts"
    end
  end

  # ---- helpers ----

  # Both screens turn the browser away to the entry surface, and the surface it
  # lands on carries the notice and none of the project's data.
  defp assert_asked_to_sign_in_again(hosted, project) do
    for path <- [~p"/projects", ~p"/projects/#{project.id}/overview"] do
      assert {:error, {:redirect, %{to: @entry_with_notice}}} = live(hosted_conn(hosted), path)

      turned_away = get(hosted_conn(hosted), path)
      assert redirected_to(turned_away) == @entry_with_notice

      entry = get(hosted_conn(hosted), @entry_with_notice)
      body = html_response(entry, 200)

      assert body =~ @sign_in_notice
      assert body =~ "Login with GitHub"

      # Absence asserted against the body, not inferred from the redirect.
      refute body =~ project.name
      refute body =~ project.id
      refute body =~ project.workspace_id
      refute body =~ project.canonical_repository_id
      refute body =~ repository_display_name()
      refute body =~ "In my SDD Orchestrator account"
      refute body =~ ~s(data-screen="project-dashboard")
      refute body =~ "data-project-row"
    end
  end

  # A hosted project whose repository is on this person's Mac: the only kind a
  # passwordless owner can create today (`specs/44`).
  defp hosted_local_project(workspace, name) do
    device = ProjectsFixtures.device_workspace_fixture()

    attempt =
      ProjectsFixtures.device_attempt_ready_for_hosted(device, workspace,
        repository: ProjectsFixtures.local_repository_metadata(name: repository_display_name())
      )

    {:ok, project} = Projects.register_project(workspace, attempt, name: name)
    project
  end

  # A folder name no layout, notice, or asset path would contain by accident, so
  # the absence assertions mean what they say.
  defp repository_display_name, do: "ledger-of-receipts-folder"

  defp hosted_conn(hosted) do
    Plug.Test.init_test_session(
      build_conn(),
      %{SessionCookie.session_key() => hosted.session_cookie.value}
    )
  end

  # The live routes whose live session mounts the application-session gate.
  # Keyed on the hook rather than on a live-session name, so a new live session
  # that requires the application session joins the review on its own.
  defp application_session_routes do
    Router.__routes__()
    |> Enum.filter(fn route ->
      case route.metadata[:phoenix_live_view] do
        {_module, _action, _opts, live_session} -> application_session_only?(live_session)
        _other -> false
      end
    end)
  end

  defp application_session_only?(%{extra: %{on_mount: hooks}}) do
    Enum.any?(hooks, &(&1.id == @application_session_hook))
  end

  defp application_session_only?(_live_session), do: false

  defp concrete_path(path) do
    path
    |> String.split("/")
    |> Enum.map_join("/", fn
      ":" <> _param -> Ecto.UUID.generate()
      segment -> segment
    end)
  end

  defp delivered_verification_path(email) do
    [url] = Regex.run(~r{https?://\S+}, email.text_body)
    %URI{path: path, query: query} = URI.parse(url)
    path <> "?" <> query
  end

  defp verified_return(return_to), do: [status: "verified", return_to: return_to]

  defp stub_folder(path) do
    Application.put_env(:sdd_orchestrator, :device_worker_stub_folder, path)
    on_exit(fn -> Application.delete_env(:sdd_orchestrator, :device_worker_stub_folder) end)
  end

  defp store_path do
    dir = Path.join(System.tmp_dir!(), "sdd_hosted_access_#{System.unique_integer([:positive])}")
    Path.join(dir, "store.dets")
  end

  defp git_repo_fixture do
    dir = Path.join(System.tmp_dir!(), "sdd_repo_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    {_, 0} = System.cmd("git", ["-C", dir, "init", "--quiet"], stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["-C", dir, "config", "user.email", "t@example.com"])
    {_, 0} = System.cmd("git", ["-C", dir, "config", "user.name", "Test"])
    File.write!(Path.join(dir, "README.md"), "hello #{System.unique_integer([:positive])}")
    {_, 0} = System.cmd("git", ["-C", dir, "add", "."], stderr_to_stdout: true)

    {_, 0} =
      System.cmd("git", ["-C", dir, "commit", "-m", "init", "--quiet"], stderr_to_stdout: true)

    dir
  end
end
