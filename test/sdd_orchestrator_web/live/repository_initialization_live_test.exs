defmodule SddOrchestratorWeb.RepositoryInitializationLiveTest do
  @moduledoc """
  Task 2 proof: discovery, target selection (empty and unborn accepted;
  non-empty, mature, and inaccessible rejected with a clear message and no
  plan created), and the guided-question flow through every field in order —
  including rejecting an out-of-order field submission at the LiveView level
  — reaching `"ready"`.

  The device store is a singleton GenServer not started in test, so each test
  starts its own isolated instance on a unique path in an `async: false` case
  (mirrors `LocalOnboardingLiveTest`).
  """
  use SddOrchestratorWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.DeviceStore.Local
  alias SddOrchestrator.Devices.Pairing

  setup do
    path = store_path()
    on_exit(fn -> File.rm_rf!(Path.dirname(path)) end)
    start_supervised!({Local, path: path})
    {:ok, workspace} = Devices.establish_workspace()
    %{workspace: workspace}
  end

  describe "discovery" do
    test "shows the worker-missing state with a pairing form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/onboarding/empty-repository")

      assert has_element?(view, "[data-worker-status=missing]")
      assert has_element?(view, "form[phx-submit=pair]")
    end

    test "pairing the worker stand-in advances to the detected state", %{
      conn: conn,
      workspace: workspace
    } do
      {:ok, view, _html} = live(conn, ~p"/onboarding/empty-repository")

      view
      |> form("#pairing-form", pairing: %{code: "ANYCODE"})
      |> render_submit()

      assert has_element?(view, "[data-worker-status=detected]")
      assert Devices.worker_status(workspace.id) == :detected
    end
  end

  describe "target selection" do
    test "an empty directory is accepted and starts a plan", %{conn: conn, workspace: workspace} do
      pair(workspace.id)
      dir = empty_dir_fixture()
      on_exit(fn -> File.rm_rf!(dir) end)
      stub_folder(dir)

      {:ok, view, _html} = live(conn, ~p"/onboarding/empty-repository")
      render_click(view, "continue_to_selection")
      render_click(view, "select_folder")

      assert has_element?(view, "[data-step=guided-questions]")
      assert has_element?(view, "[data-current-field=purpose]")
    end

    test "an unborn Git repository is accepted and starts a plan", %{
      conn: conn,
      workspace: workspace
    } do
      pair(workspace.id)
      dir = unborn_repo_fixture()
      on_exit(fn -> File.rm_rf!(dir) end)
      stub_folder(dir)

      {:ok, view, _html} = live(conn, ~p"/onboarding/empty-repository")
      render_click(view, "continue_to_selection")
      render_click(view, "select_folder")

      assert has_element?(view, "[data-step=guided-questions]")
    end

    test "a non-empty non-Git directory is rejected without creating a plan", %{
      conn: conn,
      workspace: workspace
    } do
      pair(workspace.id)
      dir = empty_dir_fixture()
      on_exit(fn -> File.rm_rf!(dir) end)
      File.write!(Path.join(dir, "notes.txt"), "hello")
      stub_folder(dir)

      {:ok, view, _html} = live(conn, ~p"/onboarding/empty-repository")
      render_click(view, "continue_to_selection")
      render_click(view, "select_folder")

      assert has_element?(view, "[data-target-error]", "existing files")
      assert has_element?(view, "[data-step=selecting-target]")
    end

    test "a mature (existing-commit) repository is rejected without creating a plan", %{
      conn: conn,
      workspace: workspace
    } do
      pair(workspace.id)
      dir = git_repo_with_commit_fixture()
      on_exit(fn -> File.rm_rf!(dir) end)
      stub_folder(dir)

      {:ok, view, _html} = live(conn, ~p"/onboarding/empty-repository")
      render_click(view, "continue_to_selection")
      render_click(view, "select_folder")

      assert has_element?(view, "[data-target-error]", "already has commits")
      assert has_element?(view, "[data-step=selecting-target]")
    end

    test "an inaccessible path is rejected without creating a plan", %{
      conn: conn,
      workspace: workspace
    } do
      pair(workspace.id)
      stub_folder("/no/such/path/#{System.unique_integer([:positive])}")

      {:ok, view, _html} = live(conn, ~p"/onboarding/empty-repository")
      render_click(view, "continue_to_selection")
      render_click(view, "select_folder")

      assert has_element?(view, "[data-target-error]")
      assert has_element?(view, "[data-step=selecting-target]")
    end
  end

  describe "guided questions" do
    setup %{conn: conn, workspace: workspace} do
      pair(workspace.id)
      dir = empty_dir_fixture()
      on_exit(fn -> File.rm_rf!(dir) end)
      stub_folder(dir)

      {:ok, view, _html} = live(conn, ~p"/onboarding/empty-repository")
      render_click(view, "continue_to_selection")
      render_click(view, "select_folder")

      %{view: view}
    end

    test "walking every field in order reaches ready", %{view: view} do
      assert has_element?(view, "[data-current-field=purpose]")
      answer(view, "purpose", "A CLI tool")

      assert has_element?(view, "[data-current-field=users]")
      answer(view, "users", "Founders")

      assert has_element?(view, "[data-current-field=first_outcome]")
      answer(view, "first_outcome", "First working release")

      assert has_element?(view, "[data-current-field=constraints]")
      answer(view, "constraints", "None yet")

      assert has_element?(view, "[data-current-field=technical_foundation]")
      answer(view, "technical_foundation", "Elixir + Phoenix")

      assert has_element?(view, "[data-current-field=ready]")
      assert has_element?(view, "[data-state=ready]")
      refute has_element?(view, "[data-answer-form]")
    end

    test "rejects an out-of-order field submission at the LiveView level", %{view: view} do
      render_submit(view, "submit_answer", %{"field" => "technical_foundation", "value" => "x"})

      assert has_element?(view, "[data-current-field=purpose]")
      assert render(view) =~ "already answered"
    end

    test "rejects a blank answer without advancing", %{view: view} do
      render_submit(view, "submit_answer", %{"field" => "purpose", "value" => "   "})

      assert has_element?(view, "[data-current-field=purpose]")
    end
  end

  # ---- helpers ----

  defp answer(view, field, value) do
    render_submit(view, "submit_answer", %{"field" => field, "value" => value})
  end

  defp pair(workspace_id) do
    {:ok, %{code: code}} = Pairing.start_pairing(workspace_id)

    {:ok, %{worker: worker}} =
      Pairing.complete_pairing(code, %{
        os_family: "macos",
        os_major: "15",
        protocol_version: "1",
        app_version: "1.0.0"
      })

    {:ok, seen} = Pairing.mark_seen(worker)
    seen
  end

  defp stub_folder(path) do
    Application.put_env(:sdd_orchestrator, :device_worker_stub_folder, path)
    on_exit(fn -> Application.delete_env(:sdd_orchestrator, :device_worker_stub_folder) end)
  end

  defp store_path do
    dir =
      Path.join(
        System.tmp_dir!(),
        "sdd_repository_initialization_#{System.unique_integer([:positive])}"
      )

    Path.join(dir, "store.dets")
  end

  defp empty_dir_fixture do
    dir = Path.join(System.tmp_dir!(), "sdd_ri_dir_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end

  defp unborn_repo_fixture do
    dir = empty_dir_fixture()
    {_out, 0} = System.cmd("git", ["-C", dir, "init", "--quiet"], stderr_to_stdout: true)
    dir
  end

  defp git_repo_with_commit_fixture do
    dir = unborn_repo_fixture()
    {_out, 0} = System.cmd("git", ["-C", dir, "config", "user.email", "t@example.com"])
    {_out, 0} = System.cmd("git", ["-C", dir, "config", "user.name", "Test"])
    File.write!(Path.join(dir, "README.md"), "hello")
    {_out, 0} = System.cmd("git", ["-C", dir, "add", "."], stderr_to_stdout: true)

    {_out, 0} =
      System.cmd("git", ["-C", dir, "commit", "-m", "init", "--quiet"], stderr_to_stdout: true)

    dir
  end
end
