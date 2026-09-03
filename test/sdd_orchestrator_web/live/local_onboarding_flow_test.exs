defmodule SddOrchestratorWeb.LocalOnboardingFlowTest do
  @moduledoc """
  Task 7 proof: the accountless local-onboarding flow runs end to end — storage-mode
  explanation, worker discovery and stub pairing, native repository selection, the
  first-connection privacy disclosure and confirmation with the accountless data-loss
  warning, atomic project registration, and the direct handoff to the new project's
  on-device dashboard. It also covers the confirm-once disclosure behavior, duplicate
  repository rejection, `Locate repository` recovery (matching restores, non-matching
  is treated as different), the project-portability recovery mention, and the mobile
  full-width call-to-action treatment.

  The device store is a singleton GenServer not started in test, so each test starts
  its own isolated instance on a unique path in an `async: false` case.

  `specs/40-worker-repository-selection` Task 7 turned the folder question into a
  request the worker answers, so every selection here is a click that waits and an
  answer that arrives a moment later. The scenarios are unchanged; they settle the
  page through `SddOrchestrator.SelectionSettling` rather than reading it once.

  `specs/44-hosted-local-repository-projects` Task 4 adds the hosted half of the
  same click path (AC-04): the person signs in at the storage step, chooses `In my
  SDD Orchestrator account`, and gets a hosted project bound to the worker that
  proved the repository. It also proves coexistence in both orders: a device
  project and a hosted project for the same repository are separate projects with
  their own storage mode, and creating one leaves the other untouched.
  """
  use SddOrchestratorWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import SddOrchestrator.SelectionSettling, only: [settle: 2]

  alias SddOrchestrator.AccountsFixtures
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.DeviceStore.Local
  alias SddOrchestrator.Devices.Pairing
  alias SddOrchestrator.Devices.PortableRepositoryIdentity
  alias SddOrchestrator.HostedAccess.SessionCookie
  alias SddOrchestrator.HostedAccessFixtures
  alias SddOrchestrator.Portability.HostedLocalRepositoryBinding
  alias SddOrchestrator.Projects
  alias SddOrchestrator.Projects.Project
  alias SddOrchestrator.ProjectsFixtures
  alias SddOrchestrator.Repo
  alias SddOrchestratorWeb.RepositoryAssessmentLive

  setup do
    path = store_path()
    on_exit(fn -> File.rm_rf!(Path.dirname(path)) end)
    start_supervised!({Local, path: path})
    {:ok, workspace} = Devices.establish_workspace()
    %{workspace: workspace}
  end

  describe "storage-mode explanation" do
    test "explains both storage modes before onboarding continues", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/onboarding/local")

      assert has_element?(view, "[data-storage-explanation]")
      html = render(view)
      assert html =~ "On this device"
      assert html =~ "In my SDD Orchestrator account"
      # Hosted storage routes out (deferred to other slices), it is not selectable here.
      assert has_element?(view, "[data-storage-explanation] a[href*='/hosted/access']")
    end
  end

  describe "full local onboarding flow" do
    test "pairs, selects, discloses, confirms, creates, and opens the dashboard", %{
      conn: conn,
      repo: repo
    } do
      stub_folder(repo)
      {:ok, view, _html} = live(conn, ~p"/onboarding/local")

      # Worker discovery: pair through the stand-in, reaching a detected worker.
      assert has_element?(view, "[data-worker-status=missing]")

      view
      |> form("[data-pairing-form]", pairing: %{code: "4K7Q-2P9X"})
      |> render_submit()

      assert has_element?(view, "[data-worker-status=detected]")

      # The worker is asked for the repository and answers with its folder name.
      render_click(view, "continue_to_selection")
      assert render_click(view, "select_folder") =~ "data-selection-waiting"
      settle(view, "data-selected-repository")
      assert has_element?(view, "[data-repository-name]", Path.basename(repo))

      # The worker reported verdicts and a folder name. There is no path to show.
      refute render(view) =~ repo

      # First-connection disclosure with the accountless data-loss warning.
      view = proceed_to_review(conn, view)
      assert has_element?(view, "[data-disclosure]")
      disclosure = render(view)
      assert disclosure =~ "never leave this computer"
      assert disclosure =~ "no account"
      assert disclosure =~ "project portability"
      assert disclosure =~ "independent connection gets a different identifier"
      assert disclosure =~ "explicitly export and restore this same project"

      # Create is gated on confirmation.
      assert has_element?(view, "[data-create][disabled]")
      render_click(view, "toggle_disclosure")
      refute has_element?(view, "[data-create][disabled]")

      view
      |> form("[data-step=review] form", project: %{name: "My Local Project"})
      |> render_submit()

      {to, _flash} = assert_redirect(view)
      assert to =~ ~r"^/local/projects/"

      # One project was created atomically and the dashboard opens on it.
      assert [project] = Devices.list_projects()
      assert project.name == "My Local Project"
      assert project.storage_mode == "device"

      assert {:ok, _portable} =
               PortableRepositoryIdentity.parse(project.repository_fingerprint)

      {:ok, _dash, dash_html} = live(conn, to)
      assert dash_html =~ "My Local Project"
      assert dash_html =~ "On this device"
      assert dash_html =~ "Repository identity ready for export"
    end

    test "does not send metadata when the disclosure is not confirmed", %{conn: conn, repo: repo} do
      {:ok, view, _html} = seed_detected_and_select(conn, repo)
      view = proceed_to_review(conn, view)

      # Attempting to create without confirming keeps the user in review and creates nothing.
      view
      |> form("[data-step=review] form", project: %{name: "Unconfirmed"})
      |> render_submit()

      assert has_element?(view, "[data-step=review]")
      assert Devices.list_projects() == []
    end
  end

  describe "confirm-once disclosure" do
    test "a later connection keeps the disclosure accessible without re-prompting", %{conn: conn} do
      # First project confirms the disclosure.
      {:ok, %{id: _}} =
        Devices.register_project(%{
          name: "Existing",
          repository_fingerprint: "fp-existing",
          status: "connected"
        })

      other = git_repo_fixture()
      on_exit(fn -> File.rm_rf!(other) end)

      {:ok, view, _html} = seed_detected_and_select(conn, other)
      view = proceed_to_review(conn, view)

      # No forced confirmation, but the disclosure stays available behind a disclosure control.
      refute has_element?(view, "[data-confirm-disclosure]")
      assert has_element?(view, "[data-disclosure-summary]")
      # Create is enabled immediately (disclosure already confirmed once).
      refute has_element?(view, "[data-create][disabled]")
    end
  end

  describe "one project per repository" do
    test "rejects a repository that is already connected", %{conn: conn, repo: repo} do
      {:ok, view, _html} = seed_detected_and_select(conn, repo)
      view = proceed_to_review(conn, view)
      render_click(view, "toggle_disclosure")

      view
      |> form("[data-step=review] form", project: %{name: "First"})
      |> render_submit()

      assert_redirect(view)
      assert [one] = Devices.list_projects()

      # The worker compares the selected repository against the workspace's
      # authorized identities and blocks it before allocating another identity.
      stub_folder(repo)
      {:ok, view2, _html} = live(conn, ~p"/onboarding/local")
      render_click(view2, "continue_to_selection")
      render_click(view2, "select_folder")

      assert settle(view2, "data-duplicate") =~ "already connected"
      assert has_element?(view2, "[data-step=selection] [data-duplicate]")
      refute has_element?(view2, "[data-selected-repository]")
      assert [^one] = Devices.list_projects()
    end
  end

  # `specs/44-hosted-local-repository-projects` Task 4. The same path a person
  # walks, up to the storage step where they sign in and choose to save the
  # project to their account instead of to this Mac.
  describe "full hosted local onboarding flow" do
    test "pairs, selects, chooses hosted storage, confirms, and opens the hosted project", %{
      conn: conn,
      repo: repo,
      workspace: workspace
    } do
      hosted = HostedAccessFixtures.verified_hosted_session_fixture()
      stub_folder(repo)

      {:ok, view, _html} = live(conn, ~p"/onboarding/local")

      view
      |> form("[data-pairing-form]", pairing: %{code: "4K7Q-2P9X"})
      |> render_submit()

      assert has_element?(view, "[data-worker-status=detected]")

      render_click(view, "continue_to_selection")
      render_click(view, "select_folder")
      settle(view, "data-selected-repository")
      assert has_element?(view, "[data-repository-name]", Path.basename(repo))

      # The storage step is where the account arrives. Nothing is created there.
      review = proceed_to_hosted_review(conn, view, hosted)
      assert Repo.aggregate(Project, :count) == 0

      render_click(review, "toggle_disclosure")

      review
      |> form("[data-step=review] form", project: %{name: "Hosted Ledger"})
      |> render_submit()

      project = Repo.one!(Project)
      assert_redirect(review, "/projects/#{project.id}")

      # One hosted project, saved to the account this flow's own sign-in proved.
      assert project.name == "Hosted Ledger"
      assert project.workspace_id == hosted.personal_workspace.id
      assert project.storage_mode == "hosted"
      assert project.repository_provider == "local"

      # Its repository link is the portable identity the worker generated, and it
      # still proves this repository.
      assert {:ok, _portable} = PortableRepositoryIdentity.parse(project.canonical_repository_id)
      assert {:ok, true} = PortableRepositoryIdentity.match(repo, project.canonical_repository_id)

      # The Mac that proved the repository is bound to the project.
      binding = Repo.get_by!(HostedLocalRepositoryBinding, project_id: project.id)
      assert [worker] = Pairing.active_workers(workspace.id)
      assert binding.worker_id == worker.id

      # A hosted project writes nothing to the device store.
      assert Devices.list_projects() == []
    end
  end

  # AC-04. Two projects for one repository: one saved to this Mac, one saved to an
  # account. They are separate records with their own storage mode, and neither is
  # merged, migrated, or changed when the other is created.
  describe "a device project and a hosted project for the same repository" do
    test "creating the device one after the hosted one leaves the hosted one untouched", %{
      conn: conn,
      repo: repo
    } do
      hosted = HostedAccessFixtures.verified_hosted_session_fixture()

      # Hosted first, driven entirely through the click path.
      {:ok, view, _html} = seed_detected_and_select(conn, repo)
      hosted_review = proceed_to_hosted_review(conn, view, hosted)
      render_click(hosted_review, "toggle_disclosure")

      hosted_review
      |> form("[data-step=review] form", project: %{name: "Ledger In Account"})
      |> render_submit()

      hosted_project = Repo.one!(Project)
      assert_redirect(hosted_review)

      # The hosted project lives in PostgreSQL, so the device store still holds
      # nothing and this Mac sees the repository as unconnected. The device half
      # therefore runs through the same click path too.
      assert Devices.list_projects() == []

      {:ok, second, _html} = seed_detected_and_select(conn, repo)
      device_review = proceed_to_review(conn, second)
      render_click(device_review, "toggle_disclosure")

      device_review
      |> form("[data-step=review] form", project: %{name: "Ledger On This Mac"})
      |> render_submit()

      assert_redirect(device_review)
      assert [device_project] = Devices.list_projects()

      assert_coexist(repo, hosted_project, device_project)

      # The hosted project was not merged, migrated, or renamed by the second one.
      reloaded = Repo.get!(Project, hosted_project.id)
      assert reloaded == hosted_project
    end

    test "creating the hosted one after the device one leaves the device one untouched", %{
      conn: conn,
      repo: repo,
      workspace: workspace
    } do
      # Device first, driven entirely through the click path.
      {:ok, view, _html} = seed_detected_and_select(conn, repo)
      device_review = proceed_to_review(conn, view)
      render_click(device_review, "toggle_disclosure")

      device_review
      |> form("[data-step=review] form", project: %{name: "Ledger On This Mac"})
      |> render_submit()

      assert_redirect(device_review)
      assert [device_project] = Devices.list_projects()

      # This order cannot be driven through the screen: the worker compares the
      # folder against the identities this Mac already holds, so a second
      # selection is refused as a duplicate before it can reach the storage step.
      # The hosted half therefore runs from the domain instead.
      stub_folder(repo)
      {:ok, blocked, _html} = live(conn, ~p"/onboarding/local")
      render_click(blocked, "continue_to_selection")
      render_click(blocked, "select_folder")
      assert settle(blocked, "data-duplicate") =~ "already connected"

      hosted_project = register_hosted_from_domain(workspace, repo, "Ledger In Account")

      assert_coexist(repo, hosted_project, device_project)

      # The device project was not merged, migrated, or reassigned by the hosted
      # one: the same record, unchanged, is still the only one on this Mac.
      assert {:ok, unchanged} = Devices.get_project(device_project.id)
      assert unchanged == device_project
    end
  end

  describe "Locate repository recovery" do
    # Locating asks a worker now, so these scenarios need one attached. The test
    # that proves the refusal turns the stand-in off for itself.
    setup %{workspace: workspace} do
      workspace.id |> pair(%{os_major: "26"}) |> seen_now()
      :ok
    end

    test "a matching repository restores the connection", %{conn: conn, repo: repo, workspace: ws} do
      {:ok, %{fingerprint: fp}} = Devices.RepositoryValidation.validate(repo, ws.id)

      {:ok, project} =
        Devices.register_project(%{
          name: "Moved Project",
          repository_fingerprint: fp,
          status: "connected"
        })

      stub_folder(repo)
      {:ok, view, _html} = live(conn, ~p"/onboarding/local?#{[locate: project.id]}")

      assert has_element?(view, "[data-step=selection][data-locate=true]")
      render_click(view, "select_folder")

      {to, flash} = assert_redirect(view, 5_000)
      assert to == "/local/projects/#{project.id}"
      assert flash["info"] =~ "ready for future project exports"

      assert {:ok, upgraded} = Devices.get_project(project.id)
      refute upgraded.repository_fingerprint == fp

      assert {:ok, _portable} =
               PortableRepositoryIdentity.parse(upgraded.repository_fingerprint)
    end

    test "a non-matching repository is treated as different and does not replace", %{
      conn: conn,
      repo: repo,
      workspace: ws
    } do
      {:ok, %{fingerprint: fp}} = Devices.RepositoryValidation.validate(repo, ws.id)

      {:ok, project} =
        Devices.register_project(%{
          name: "Original",
          repository_fingerprint: fp,
          status: "connected"
        })

      other = git_repo_fixture()
      on_exit(fn -> File.rm_rf!(other) end)
      stub_folder(other)

      {:ok, view, _html} = live(conn, ~p"/onboarding/local?#{[locate: project.id]}")
      render_click(view, "select_folder")

      assert settle(view, "data-selection-error") =~ "different repository"
      refute has_element?(view, "[data-selected-repository]")
      assert {:ok, unchanged} = Devices.get_project(project.id)
      assert unchanged.repository_fingerprint == fp
    end

    test "a portable identity reconnects exactly without replacement", %{
      conn: conn,
      repo: repo,
      workspace: workspace
    } do
      {:ok, %{fingerprint: identity}} = Devices.select_repository(repo, workspace)

      {:ok, project} =
        Devices.register_project(%{
          name: "Portable",
          repository_fingerprint: identity,
          status: "connected"
        })

      stub_folder(repo)
      {:ok, view, _html} = live(conn, ~p"/onboarding/local?#{[locate: project.id]}")
      render_click(view, "select_folder")

      {to, _flash} = assert_redirect(view, 5_000)
      assert to == "/local/projects/#{project.id}"
      assert {:ok, unchanged} = Devices.get_project(project.id)
      assert unchanged.repository_fingerprint == identity
    end

    test "an unavailable worker leaves the legacy identity unchanged", %{
      conn: conn,
      repo: repo,
      workspace: workspace
    } do
      {:ok, %{fingerprint: legacy}} = Devices.RepositoryValidation.validate(repo, workspace.id)

      {:ok, project} =
        Devices.register_project(%{
          name: "Unavailable",
          repository_fingerprint: legacy,
          status: "unavailable"
        })

      # The worker paired in this describe's setup has nothing attached, which is
      # what unavailable means here. The stand-in that counts a paired worker as
      # attached is off, so availability is read where it really lives.
      Application.put_env(:sdd_orchestrator, :device_worker_stub, false)
      on_exit(fn -> Application.put_env(:sdd_orchestrator, :device_worker_stub, true) end)

      {:ok, view, _html} = live(conn, ~p"/onboarding/local?#{[locate: project.id]}")
      html = render_click(view, "select_folder")

      # No worker was asked, so no panel is waiting on an answer.
      assert html =~ "data-selection-error"
      assert html =~ RepositoryAssessmentLive.worker_unavailable_message()
      refute html =~ "data-selection-waiting"
      assert {:ok, unchanged} = Devices.get_project(project.id)
      assert unchanged.repository_fingerprint == legacy
    end
  end

  describe "mobile call-to-action treatment" do
    test "the primary actions are full-width on mobile and never wrap", %{conn: conn, repo: repo} do
      {:ok, view, _html} = seed_detected_and_select(conn, repo)

      # Full-width on mobile, auto width from the small breakpoint up.
      assert render(view) =~ ~s(w-full sm:w-auto)
      # Buttons never wrap their label (shared button base class).
      assert render(view) =~ "whitespace-nowrap"
    end
  end

  # ---- helpers ----

  # Most tests need a git repository to select; provide it and clean it up.
  setup do
    repo = git_repo_fixture()
    on_exit(fn -> File.rm_rf!(repo) end)
    %{repo: repo}
  end

  # Drives the shared storage step: from a selected repository, hand off to the
  # storage step, choose on-device (available via the worker readiness receipt),
  # and return to the review step. Returns the resumed review view.
  defp proceed_to_review(conn, view) do
    render_click(view, "continue_to_storage")
    {storage_to, _flash} = assert_redirect(view)
    assert storage_to =~ ~r"^/onboarding/local/storage/"

    {:ok, storage_view, _html} = live(conn, storage_to)
    storage_view |> element("#storage-device") |> render_click()
    storage_view |> element("button[phx-click=continue]") |> render_click()
    {review_to, _flash} = assert_redirect(storage_view)

    {:ok, review_view, _html} = live(conn, review_to)
    assert has_element?(review_view, "[data-step=review]")
    review_view
  end

  # The hosted sibling of `proceed_to_review/2`. Hosted storage becomes available
  # only once the step records the workspace a verified sign-in proved, which it
  # reads from the hosted session cookie on mount, so the step is opened on a
  # signed-in connection.
  defp proceed_to_hosted_review(conn, view, hosted) do
    render_click(view, "continue_to_storage")
    {storage_to, _flash} = assert_redirect(view)
    assert storage_to =~ ~r"^/onboarding/local/storage/"

    signed_in =
      init_test_session(conn, %{SessionCookie.session_key() => hosted.session_cookie.value})

    {:ok, storage_view, _html} = live(signed_in, storage_to)
    storage_view |> element("#storage-hosted") |> render_click()
    storage_view |> element("button[phx-click=continue]") |> render_click()
    {review_to, _flash} = assert_redirect(storage_view)

    {:ok, review_view, _html} = live(signed_in, review_to)
    assert has_element?(review_view, "[data-step=review]")
    review_view
  end

  # The hosted half of the coexistence check when the screen refuses to run it:
  # the same worker, the same repository, and a fresh identity generated the way
  # the worker generates one, committed through the real registration.
  defp register_hosted_from_domain(workspace, repo, name) do
    hosted = ProjectsFixtures.workspace_fixture(AccountsFixtures.account_fixture())
    {:ok, identity} = PortableRepositoryIdentity.generate(repo)
    worker = ProjectsFixtures.attached_worker_fixture(workspace)

    attempt =
      ProjectsFixtures.device_attempt_ready_for_hosted(workspace, hosted,
        repository: %{fingerprint: identity, name: Path.basename(repo)},
        worker_id: worker.id
      )

    {:ok, project} = Projects.register_project(hosted, attempt, name: name)
    project
  end

  # Two separate projects for one repository. Each keeps its own id, name, storage
  # mode, and repository identity, and each identity still proves that same
  # repository: independent connections get different identifiers by design.
  defp assert_coexist(repo, hosted_project, device_project) do
    assert hosted_project.id != device_project.id
    assert hosted_project.storage_mode == "hosted"
    assert device_project.storage_mode == "device"
    assert hosted_project.name != device_project.name

    refute device_project.repository_fingerprint == hosted_project.canonical_repository_id

    assert {:ok, true} =
             PortableRepositoryIdentity.match(repo, hosted_project.canonical_repository_id)

    assert {:ok, true} =
             PortableRepositoryIdentity.match(repo, device_project.repository_fingerprint)

    # Neither store gained or lost a project behind the other's back.
    assert Repo.aggregate(Project, :count) == 1
    assert length(Devices.list_projects()) == 1
  end

  defp seed_detected_and_select(conn, repo) do
    {:ok, workspace} = Devices.get_workspace()
    workspace.id |> pair(%{os_major: "26"}) |> seen_now()
    stub_folder(repo)

    {:ok, view, html} = live(conn, ~p"/onboarding/local")
    assert has_element?(view, "[data-worker-status=detected]")
    render_click(view, "continue_to_selection")
    render_click(view, "select_folder")
    settle(view, "data-selected-repository")
    {:ok, view, html}
  end

  defp pair(workspace_id, worker_attrs) do
    {:ok, %{code: code}} = Pairing.start_pairing(workspace_id)

    {:ok, %{worker: worker}} =
      Pairing.complete_pairing(
        code,
        Map.merge(%{os_family: "macos", os_major: "26", protocol_version: "1"}, worker_attrs)
      )

    worker
  end

  defp seen_now(worker) do
    {:ok, seen} = Pairing.mark_seen(worker)
    seen
  end

  defp stub_folder(path) do
    Application.put_env(:sdd_orchestrator, :device_worker_stub_folder, path)
    on_exit(fn -> Application.delete_env(:sdd_orchestrator, :device_worker_stub_folder) end)
  end

  defp store_path do
    dir = Path.join(System.tmp_dir!(), "sdd_local_flow_#{System.unique_integer([:positive])}")
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
