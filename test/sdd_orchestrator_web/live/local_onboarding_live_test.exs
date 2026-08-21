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
  """
  use SddOrchestratorWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.DeviceStore.Local
  alias SddOrchestrator.Devices.Pairing

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
      assert html =~ "Download the worker for macOS"
      assert html =~ "pairing code"

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
      assert html =~ "not running"
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

    test "a detected worker continues to native folder selection and shows the repository", %{
      conn: conn,
      workspace: workspace,
      repo: repo
    } do
      workspace.id |> pair(%{os_major: "26"}) |> seen_now()
      stub_folder(repo)

      {:ok, view, _html} = live(conn, ~p"/onboarding/local")

      render_click(view, "continue_to_selection")
      assert has_element?(view, "[data-step=selection]")

      render_click(view, "select_folder")

      assert has_element?(view, "[data-selected-repository]")
      assert has_element?(view, "[data-repository-name]", Path.basename(repo))
      assert render(view) =~ repo
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

      assert has_element?(view, "[data-selection-error]", "Git repository")
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

      assert has_element?(view, "[data-selection-error]")
      refute has_element?(view, "[data-selected-repository]")
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

  # ---- helpers ----

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
    File.write!(Path.join(dir, "README.md"), "hello")
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
