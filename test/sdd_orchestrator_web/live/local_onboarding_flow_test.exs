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
  """
  use SddOrchestratorWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.DeviceStore.Local
  alias SddOrchestrator.Devices.Pairing
  alias SddOrchestrator.Devices.PortableRepositoryIdentity

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

      # Native selection of the repository.
      render_click(view, "continue_to_selection")
      render_click(view, "select_folder")
      assert has_element?(view, "[data-selected-repository]")
      assert has_element?(view, "[data-repository-name]", Path.basename(repo))

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

      assert has_element?(view2, "[data-step=selection] [data-duplicate]")
      assert render(view2) =~ "already connected"
      refute has_element?(view2, "[data-selected-repository]")
      assert [^one] = Devices.list_projects()
    end
  end

  describe "Locate repository recovery" do
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

      {to, _flash} = assert_redirect(view)
      assert to == "/local/projects/#{project.id}"

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

      assert has_element?(view, "[data-selection-error]", "different repository")
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

      {to, _flash} = assert_redirect(view)
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

      Application.put_env(:sdd_orchestrator, :device_worker_stub, false)
      on_exit(fn -> Application.put_env(:sdd_orchestrator, :device_worker_stub, true) end)

      {:ok, view, _html} = live(conn, ~p"/onboarding/local?#{[locate: project.id]}")
      render_click(view, "select_folder")

      assert has_element?(view, "[data-selection-error]", "Connect the worker")
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

  defp seed_detected_and_select(conn, repo) do
    {:ok, workspace} = Devices.get_workspace()
    workspace.id |> pair(%{os_major: "15"}) |> seen_now()
    stub_folder(repo)

    {:ok, view, html} = live(conn, ~p"/onboarding/local")
    assert has_element?(view, "[data-worker-status=detected]")
    render_click(view, "continue_to_selection")
    render_click(view, "select_folder")
    assert has_element?(view, "[data-selected-repository]")
    {:ok, view, html}
  end

  defp pair(workspace_id, worker_attrs) do
    {:ok, %{code: code}} = Pairing.start_pairing(workspace_id)

    {:ok, %{worker: worker}} =
      Pairing.complete_pairing(
        code,
        Map.merge(%{os_family: "macos", os_major: "15", protocol_version: "1"}, worker_attrs)
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
