defmodule SddOrchestratorWeb.LocalOnboardingLiveTest do
  @moduledoc """
  Task 2 proof: the accountless local-onboarding page classifies the local worker
  through `Devices.worker_status/1` and renders actionable guidance for each of the
  four discovery states — missing, incompatible, unavailable, and detected — with
  graphical installation and pairing guidance that never asks for a terminal
  command. It also drives the local worker stand-in through pairing into repository
  selection so the accountless graphical flow is exercisable without the signed
  native worker.

  The device store is a singleton GenServer not started in test, so each test
  starts its own isolated instance on a unique path in an `async: false` case.

  `specs/40-worker-repository-selection` Task 8 adds the truthful-report proof at
  the bottom: `Check again` reports only what the control plane knows, the
  `Code accepted` panel appears only after this session accepted a code, and an
  unavailable worker can be paired again without losing the worker it has.

  Task 7 reshapes repository selection into a request the worker answers. The
  click renders a waiting state and the verdicts arrive a moment later, so those
  proofs settle the page through `SddOrchestrator.SelectionSettling` instead of
  reading it once.
  """
  use SddOrchestratorWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import SddOrchestrator.SelectionSettling, only: [settle: 2]

  alias SddOrchestrator.Delivery.WorkerAttachment
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.DeviceStore.Local
  alias SddOrchestrator.Devices.PortableRepositoryIdentity
  alias SddOrchestrator.Devices.RepositoryValidation
  alias SddOrchestrator.Devices.{Pairing, PairingIssuanceThrottle, WorkerDiscovery}
  alias SddOrchestrator.Projects
  alias SddOrchestratorWeb.RepositoryAssessmentLive

  # Shell-command shapes that would mean the user was asked to use a terminal.
  @terminal_markers [
    "sudo",
    "brew ",
    "curl ",
    "chmod",
    "bash",
    "/bin/sh",
    "npm install",
    "$ ",
    "```"
  ]

  setup do
    path = store_path()
    on_exit(fn -> File.rm_rf!(Path.dirname(path)) end)
    start_supervised!({Local, path: path})
    {:ok, workspace} = Devices.establish_workspace()
    %{workspace: workspace}
  end

  describe "worker discovery states" do
    test "is missing with no paired worker and gives terminal-free install + pairing guidance", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/onboarding/local")

      html = render(view)
      assert has_element?(view, "[data-worker-status=missing]")
      assert has_element?(view, "[data-state=missing]")

      # Graphical installation and pairing guidance.
      assert has_element?(view, "a[href='/downloads/worker']")
      assert has_element?(view, "form[phx-submit=pair]")

      # The page states only what the control plane knows: nothing is paired. It
      # cannot see whether the app is installed, so it points at the menu bar.
      assert html =~ "This Mac has no paired worker yet."

      assert html =~
               "If the worker app is already installed, the code you need is in its menu bar."

      assert html =~ "Open the worker app"
      assert html =~ "Look for its icon in the menu bar at the top of your screen."
      assert html =~ "Copy the code"
      assert html =~ "the top line that says &quot;Not paired&quot;"
      assert html =~ "Paste it here"
      assert html =~ "The code works once, and only on this Mac."

      # The supported window comes from the computed policy, never a literal.
      majors = Enum.join(WorkerDiscovery.compatibility_policy().os_majors, " and ")
      assert html =~ "Works on macOS #{majors}."

      refute_terminal_commands(html)
    end

    test "is incompatible for an unsupported worker with update/reinstall guidance", %{
      conn: conn,
      workspace: workspace
    } do
      pair(workspace.id, %{os_major: "13"})

      {:ok, view, _html} = live(conn, ~p"/onboarding/local")

      html = render(view)
      assert has_element?(view, "[data-worker-status=incompatible]")
      assert has_element?(view, "[data-state=incompatible]")
      assert html =~ "too old"
      # Replacement pairing is offered after an update/reinstall.
      assert has_element?(view, "a[href='/downloads/worker']")
      assert has_element?(view, "form[phx-submit=pair]")

      refute_terminal_commands(html)
    end

    test "is unavailable for a paired-but-not-running worker and keeps projects visible", %{
      conn: conn,
      workspace: workspace
    } do
      # Compatible worker that has never reported in (never seen) is unavailable.
      pair(workspace.id, %{os_major: "26"})

      {:ok, view, _html} = live(conn, ~p"/onboarding/local")

      html = render(view)
      assert has_element?(view, "[data-worker-status=unavailable]")
      assert has_element?(view, "[data-state=unavailable]")
      # The one owned wording, read from its owner: the screen states that no
      # worker is attached, never that the app is stopped or missing.
      assert html =~ RepositoryAssessmentLive.worker_unavailable_message()
      assert html =~ "still listed"
      assert has_element?(view, "[data-recheck]")

      refute_terminal_commands(html)
    end

    test "is detected for a compatible worker seen recently and offers to continue", %{
      conn: conn,
      workspace: workspace
    } do
      workspace.id |> pair(%{os_major: "26"}) |> seen_now()

      {:ok, view, _html} = live(conn, ~p"/onboarding/local")

      assert has_element?(view, "[data-worker-status=detected]")
      assert has_element?(view, "[data-state=detected]")
      assert has_element?(view, "[data-continue]")
      assert render(view) =~ "Worker connected"
    end

    test "re-checks worker status on demand", %{conn: conn, workspace: workspace} do
      pair(workspace.id, %{os_major: "26"})
      {:ok, view, _html} = live(conn, ~p"/onboarding/local")
      assert has_element?(view, "[data-worker-status=unavailable]")

      # A heartbeat arrives, then the user re-checks.
      [worker] = Pairing.active_workers(workspace.id)
      seen_now(worker)

      render_click(view, "recheck")
      assert has_element?(view, "[data-worker-status=detected]")
    end
  end

  describe "stub-driven pairing" do
    test "entering a pairing code with the stand-in completes pairing into detected", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/onboarding/local")
      assert has_element?(view, "[data-worker-status=missing]")

      view
      |> form("[data-pairing-form]", pairing: %{code: "4K7Q-2P9X"})
      |> render_submit()

      assert has_element?(view, "[data-worker-status=detected]")
    end

    test "an empty pairing code is rejected without pairing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/onboarding/local")

      html =
        view
        |> form("[data-pairing-form]", pairing: %{code: "   "})
        |> render_submit()

      assert html =~ "Enter the pairing code"
      assert has_element?(view, "[data-worker-status=missing]")
    end
  end

  describe "repository selection" do
    setup do
      repo = git_repo_fixture()
      on_exit(fn -> File.rm_rf!(repo) end)
      %{repo: repo}
    end

    test "a detected worker asks the worker and shows what came back", %{
      conn: conn,
      workspace: workspace,
      repo: repo
    } do
      workspace.id |> pair(%{os_major: "26"}) |> seen_now()
      stub_folder(repo)

      {:ok, view, _html} = live(conn, ~p"/onboarding/local")

      render_click(view, "continue_to_selection")
      assert has_element?(view, "[data-step=selection]")

      # The click asks the worker and nothing more. The screen says what it asked
      # for, never that a panel is open on this Mac.
      waiting = render_click(view, "select_folder")
      assert waiting =~ "data-selection-waiting"
      assert waiting =~ "We asked the worker app to open a folder picker."
      assert waiting =~ "data-cancel-selection"

      settle(view, "data-selected-repository")
      assert has_element?(view, "[data-repository-name]", Path.basename(repo))
      refute render(view) =~ repo
    end

    test "a non-git folder is reported without selecting anything", %{
      conn: conn,
      workspace: workspace
    } do
      workspace.id |> pair(%{os_major: "26"}) |> seen_now()
      plain = plain_dir_fixture()
      on_exit(fn -> File.rm_rf!(plain) end)
      stub_folder(plain)

      {:ok, view, _html} = live(conn, ~p"/onboarding/local")
      render_click(view, "continue_to_selection")
      render_click(view, "select_folder")

      assert settle(view, "data-selection-error") =~ "Git repository"
      refute has_element?(view, "[data-selected-repository]")
    end

    test "an inaccessible folder is reported without selecting anything", %{
      conn: conn,
      workspace: workspace
    } do
      workspace.id |> pair(%{os_major: "26"}) |> seen_now()
      stub_folder("/no/such/path/#{System.unique_integer([:positive])}")

      {:ok, view, _html} = live(conn, ~p"/onboarding/local")
      render_click(view, "continue_to_selection")
      render_click(view, "select_folder")

      settle(view, "data-selection-error")
      refute has_element?(view, "[data-selected-repository]")
    end
  end

  # `specs/40-worker-repository-selection` Task 7. The folder question goes to
  # the worker and comes back as verdicts, so these prove what the screen does
  # with an answer rather than what it used to compute here from a path.
  describe "a worker-answered selection (AC-02)" do
    setup %{workspace: workspace} do
      workspace.id |> pair(%{os_major: "26"}) |> seen_now()

      repo = git_repo_fixture()
      on_exit(fn -> File.rm_rf!(repo) end)
      stub_folder(repo)

      %{repo: repo}
    end

    test "a new repository suggests its folder name and continues to the storage step", context do
      {:ok, view, _html} = live(context.conn, ~p"/onboarding/local")
      render_click(view, "continue_to_selection")
      render_click(view, "select_folder")

      settle(view, "data-selected-repository")
      assert has_element?(view, "[data-repository-name]", Path.basename(context.repo))

      render_click(view, "continue_to_storage")
      {to, _flash} = assert_redirect(view)
      assert to =~ ~r"^/onboarding/local/storage/"

      # The suggested name that travels on is the folder's own name, which is
      # the only thing about the folder the worker reported.
      attempt = Projects.get_device_onboarding_attempt(context.workspace, Path.basename(to))
      assert attempt.selected_repository["name"] == Path.basename(context.repo)
      refute attempt |> inspect(limit: :infinity) |> String.contains?(context.repo)
    end

    test "a repository the worker matched is reported as the duplicate with its link", context do
      {:ok, identity} = PortableRepositoryIdentity.generate(context.repo)

      {:ok, existing} =
        Devices.register_project(%{
          name: "Ledger",
          repository_fingerprint: identity,
          status: "connected"
        })

      {:ok, view, _html} = live(context.conn, ~p"/onboarding/local")
      render_click(view, "continue_to_selection")
      render_click(view, "select_folder")

      html = settle(view, "data-duplicate")
      assert html =~ "already connected"
      assert html =~ "Ledger"
      assert has_element?(view, "[data-duplicate] a[href='/local/projects/#{existing.id}']")
      refute has_element?(view, "[data-selected-repository]")

      # The duplicate is the worker's own match list, so nothing new was
      # allocated for a repository this workspace already holds.
      assert [^existing] = Devices.list_projects()
    end

    test "no path reaches an assign or the rendered page", context do
      {:ok, view, _html} = live(context.conn, ~p"/onboarding/local")
      render_click(view, "continue_to_selection")
      render_click(view, "select_folder")

      html = settle(view, "data-selected-repository")
      refute html =~ context.repo

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.selected.name == Path.basename(context.repo)
      assert Map.get(assigns.selected, :location) == nil
      refute assigns |> inspect(limit: :infinity) |> String.contains?(context.repo)
    end

    test "locate mode upgrades a legacy identity and leaves nothing of the old one", context do
      {:ok, %{fingerprint: legacy}} =
        RepositoryValidation.validate(context.repo, context.workspace.id)

      {:ok, project} =
        Devices.register_project(%{
          name: "Moved",
          repository_fingerprint: legacy,
          status: "unavailable"
        })

      # A second project rides along as a candidate, because the upgrade rechecks
      # that no other project holds the same repository before it replaces
      # anything. It must come through untouched.
      other_repo = git_repo_fixture()
      on_exit(fn -> File.rm_rf!(other_repo) end)
      {:ok, other_identity} = PortableRepositoryIdentity.generate(other_repo)

      {:ok, other} =
        Devices.register_project(%{
          name: "Untouched",
          repository_fingerprint: other_identity,
          status: "connected"
        })

      {:ok, view, _html} = live(context.conn, ~p"/onboarding/local?#{[locate: project.id]}")
      assert has_element?(view, "[data-step=selection][data-locate=true]")
      render_click(view, "select_folder")

      {to, flash} = assert_redirect(view, 5_000)
      assert to == "/local/projects/#{project.id}"
      assert flash["info"] =~ "ready for future project exports"

      assert {:ok, upgraded} = Devices.get_project(project.id)
      refute upgraded.repository_fingerprint == legacy
      assert {:ok, _portable} = PortableRepositoryIdentity.parse(upgraded.repository_fingerprint)
      assert Devices.find_by_fingerprint(legacy) == {:error, :not_found}
      assert Devices.get_project(other.id) == {:ok, other}
    end

    test "locate mode reports another project holding the same repository", context do
      {:ok, %{fingerprint: legacy}} =
        RepositoryValidation.validate(context.repo, context.workspace.id)

      {:ok, project} =
        Devices.register_project(%{
          name: "Moved",
          repository_fingerprint: legacy,
          status: "unavailable"
        })

      {:ok, portable} = PortableRepositoryIdentity.generate(context.repo)

      {:ok, existing} =
        Devices.register_project(%{
          name: "Already Here",
          repository_fingerprint: portable,
          status: "connected"
        })

      {:ok, view, _html} = live(context.conn, ~p"/onboarding/local?#{[locate: project.id]}")
      render_click(view, "select_folder")

      html = settle(view, "data-duplicate")
      assert html =~ "Already Here"
      assert has_element?(view, "[data-duplicate] a[href='/local/projects/#{existing.id}']")

      # The upgrade is refused whole: the legacy identity stays exactly as it was.
      assert {:ok, unchanged} = Devices.get_project(project.id)
      assert unchanged.repository_fingerprint == legacy
    end

    test "a request nobody answers offers a retry and selects nothing", context do
      {:ok, view, _html} = live(context.conn, ~p"/onboarding/local")
      render_click(view, "continue_to_selection")

      waiting = render_click(view, "select_folder")
      assert waiting =~ "data-selection-waiting"

      send(view.pid, {:repository_selection, open_request_id(view), :timeout})

      html = render(view)
      assert html =~ "data-selection-no-answer"
      assert html =~ "data-retry-selection"
      refute html =~ "data-selection-waiting"
      refute html =~ "data-selected-repository"

      # The retry is the same action again, so it opens a fresh request.
      assert render_click(view, "select_folder") =~ "data-selection-waiting"
    end

    test "an outcome for another request changes nothing", context do
      {:ok, view, _html} = live(context.conn, ~p"/onboarding/local")
      render_click(view, "continue_to_selection")
      render_click(view, "select_folder")

      send(view.pid, {:repository_selection, Ecto.UUID.generate(), :timeout})

      # The request this screen is waiting on still answers for itself.
      settle(view, "data-selected-repository")
      refute render(view) =~ "data-selection-no-answer"
    end

    test "an unavailable worker is refused instead of asked", context do
      # Paired with nothing attached, which is what `:unavailable` means. The
      # stand-in that counts a paired worker as attached is off, so availability
      # is read where it really lives.
      Application.put_env(:sdd_orchestrator, :device_worker_stub, false)
      on_exit(fn -> Application.put_env(:sdd_orchestrator, :device_worker_stub, true) end)

      {:ok, view, _html} = live(context.conn, ~p"/onboarding/local")
      render_click(view, "continue_to_selection")

      html = render_click(view, "select_folder")
      assert html =~ "data-selection-error"
      assert html =~ RepositoryAssessmentLive.worker_unavailable_message()
      refute html =~ "data-selection-waiting"
      refute html =~ "data-selected-repository"
    end
  end

  describe "project-scoped device setup entry point (?project=<id>)" do
    setup do
      {:ok, project} =
        Devices.register_project(%{
          name: "Ledger",
          repository_fingerprint: "fingerprint-#{System.unique_integer([:positive])}",
          status: "connected"
        })

      %{project: project}
    end

    test "a valid project param issues a pairing code and renders its Open in App deep link", %{
      conn: conn,
      workspace: workspace,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/onboarding/local?#{[project: project.id]}")

      assert has_element?(view, "[data-worker-status=missing]")

      link_html = view |> element("[data-open-in-app]") |> render()
      assert link_html =~ ~s(href="sddworker://pair?code=)
      assert link_html =~ "project_id=#{project.id}"

      [_, encoded_code] = Regex.run(~r/code=([^&"]+)/, link_html)
      code = URI.decode_www_form(encoded_code)

      assert {:ok, %{worker: worker}} =
               Pairing.complete_pairing(code, %{
                 os_family: "macos",
                 os_major: "26",
                 protocol_version: "1"
               })

      assert worker.device_workspace_id == workspace.id

      # Single-use: the same code can't complete a second pairing.
      assert {:error, _reason} = Pairing.complete_pairing(code, %{})
    end

    test "an unknown project param is ignored, behaving like no param at all", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/onboarding/local?#{[project: Ecto.UUID.generate()]}")

      assert has_element?(view, "[data-worker-status=missing]")
      refute has_element?(view, "[data-open-in-app]")
    end

    test "no project param renders no Open in App deep link", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/onboarding/local")

      assert has_element?(view, "[data-worker-status=missing]")
      refute has_element?(view, "[data-open-in-app]")
    end
  end

  # `specs/40-worker-repository-selection` Task 8. The stand-in answers "attached"
  # for any paired worker, so every test here turns it off and reads the real
  # availability definition. That is what makes `:unavailable` reachable at all.
  describe "a truthful worker report (AC-09, AC-10)" do
    setup do
      PairingIssuanceThrottle.reset()
      :ok
    end

    test "Check again on an unavailable worker never claims a code was accepted", %{
      conn: conn,
      workspace: workspace
    } do
      workspace.id |> pair(%{os_major: "26"}) |> seen_now()

      without_stub(fn ->
        {:ok, view, _html} = live(conn, ~p"/onboarding/local")
        assert has_element?(view, "[data-worker-status=unavailable]")
        refute has_element?(view, "[data-worker-awaiting]")

        render_click(view, "recheck")

        # The defect: any not-detected status used to render the waiting panel.
        assert has_element?(view, "[data-worker-status=unavailable]")
        assert has_element?(view, "[data-state=unavailable]")
        refute has_element?(view, "[data-worker-awaiting]")
        refute render(view) =~ "Code accepted"
      end)
    end

    test "the accepted-code panel appears only after this session accepted one", %{conn: conn} do
      {:ok, %{code: code}} = Pairing.issue_unbound_code(caller())

      without_stub(fn ->
        {:ok, view, _html} = live(conn, ~p"/onboarding/local")
        refute has_element?(view, "[data-worker-awaiting]")

        view |> form("[data-pairing-form]", pairing: %{code: code}) |> render_submit()

        assert has_element?(view, "[data-worker-awaiting]")
        assert render(view) =~ "Code accepted"
      end)
    end

    test "Pair again reveals the pairing form and its deep-link code", %{
      conn: conn,
      workspace: workspace
    } do
      workspace.id |> pair(%{os_major: "26"}) |> seen_now()
      {:ok, project} = register_project()

      without_stub(fn ->
        {:ok, view, _html} = live(conn, ~p"/onboarding/local?#{[project: project.id]}")

        assert has_element?(view, "[data-state=unavailable]")
        refute has_element?(view, "[data-pairing-form]")
        refute has_element?(view, "[data-open-in-app]")

        render_click(view, "pair_again")

        assert has_element?(view, "[data-pairing-form]")
        assert has_element?(view, "[data-state=unavailable]")

        link_html = view |> element("[data-open-in-app]") |> render()
        assert link_html =~ ~s(href="sddworker://pair?code=)
        assert link_html =~ "project_id=#{project.id}"
      end)
    end

    test "pairing again authorizes another worker and keeps the one already paired", %{
      conn: conn,
      workspace: workspace
    } do
      existing = workspace.id |> pair(%{os_major: "26"}) |> seen_now()
      assert [^existing] = Pairing.active_workers(workspace.id)

      {:ok, %{code: code}} = Pairing.issue_unbound_code(caller())

      without_stub(fn ->
        {:ok, view, _html} = live(conn, ~p"/onboarding/local")
        assert has_element?(view, "[data-state=unavailable]")

        render_click(view, "pair_again")
        view |> form("[data-pairing-form]", pairing: %{code: code}) |> render_submit()
        assert has_element?(view, "[data-worker-awaiting]")

        # The new worker finishes for itself and attaches, exactly as the app does.
        app_finishes(code)
        render_click(view, "recheck")

        # The screen reports the new worker's own state, not a remembered one.
        assert has_element?(view, "[data-worker-status=detected]")
        refute has_element?(view, "[data-worker-awaiting]")
      end)

      workers = Pairing.active_workers(workspace.id)
      assert length(workers) == 2
      assert existing.id in Enum.map(workers, & &1.id)
    end
  end

  # ---- helpers ----

  # The request this screen is waiting on. A test that drives an outcome has to
  # name the same request, because an outcome for any other one is ignored.
  defp open_request_id(view), do: :sys.get_state(view.pid).socket.assigns.selection_request_id

  # The stand-in reports every paired worker as attached, which hides the
  # unavailable state entirely. Turning it off is what makes these proofs real.
  defp without_stub(fun) do
    previous = Application.get_env(:sdd_orchestrator, :device_worker_stub)
    Application.put_env(:sdd_orchestrator, :device_worker_stub, false)

    try do
      fun.()
    after
      Application.put_env(:sdd_orchestrator, :device_worker_stub, previous)
    end
  end

  # What the worker app does once its code is bound: report the versions only it
  # knows, then attach. The attachment is what makes it available, so a screen
  # that said `detected` without one would be reading the old rule.
  defp app_finishes(code) do
    policy = WorkerDiscovery.compatibility_policy()

    {:ok, %{worker: worker}} =
      Pairing.complete_pairing(code, %{
        os_family: policy.os_family,
        os_major: List.last(policy.os_majors),
        protocol_version: List.first(policy.protocol_versions),
        app_version: "0.0.0-test"
      })

    {:ok, _seen} = Pairing.mark_seen(worker)

    {:ok, _owner} =
      WorkerAttachment.attach(worker.device_workspace_id, %{
        worker_id: worker.id,
        protocol_version: 1,
        capabilities: ["repository_selection"]
      })

    worker
  end

  defp register_project do
    Devices.register_project(%{
      name: "Ledger #{System.unique_integer([:positive])}",
      repository_fingerprint: "fingerprint-#{System.unique_integer([:positive])}",
      status: "connected"
    })
  end

  # A caller key of its own per test, so the shared issuance throttle cannot make
  # one proof depend on another.
  defp caller, do: "onboarding-#{System.unique_integer([:positive])}"

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

  defp refute_terminal_commands(html) do
    for marker <- @terminal_markers do
      refute String.contains?(html, marker),
             "install guidance must not contain the terminal marker #{inspect(marker)}"
    end
  end

  defp store_path do
    dir =
      Path.join(System.tmp_dir!(), "sdd_local_onboarding_#{System.unique_integer([:positive])}")

    Path.join(dir, "store.dets")
  end

  defp git_repo_fixture do
    dir = Path.join(System.tmp_dir!(), "sdd_repo_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    {_, 0} = System.cmd("git", ["-C", dir, "init", "--quiet"], stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["-C", dir, "config", "user.email", "t@example.com"])
    {_, 0} = System.cmd("git", ["-C", dir, "config", "user.name", "Test"])
    # Unique content, so two fixtures committed in the same second cannot share a
    # root commit and therefore a repository identity.
    File.write!(Path.join(dir, "README.md"), "hello #{System.unique_integer([:positive])}")
    {_, 0} = System.cmd("git", ["-C", dir, "add", "."], stderr_to_stdout: true)

    {_, 0} =
      System.cmd("git", ["-C", dir, "commit", "-m", "init", "--quiet"], stderr_to_stdout: true)

    dir
  end

  defp plain_dir_fixture do
    dir = Path.join(System.tmp_dir!(), "sdd_plain_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end
end
