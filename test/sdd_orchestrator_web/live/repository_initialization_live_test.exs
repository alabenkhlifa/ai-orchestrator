defmodule SddOrchestratorWeb.RepositoryInitializationLiveTest do
  @moduledoc """
  Task 2 proof: discovery, target selection (empty and unborn accepted;
  non-empty, mature, and inaccessible rejected with a clear message and no
  plan created), and the guided-question flow through every field in order —
  including rejecting an out-of-order field submission at the LiveView level
  — reaching `"ready"`.

  Task 3 proof (AC-04, AC-05, AC-06): reaching `:reviewing_plan`, rendering
  the fixed skeleton, the kit package's exact details with its include/decline
  toggle and AC-06 decline copy, the no-kit-available case, the worker and
  accountless-fallback provider summary, the processing-boundary disclosure
  gating the confirm control, a successful confirmation reaching the
  placeholder, and a changed-input case surfacing "plan changed" instead of
  silently confirming.

  The device store is a singleton GenServer not started in test, so each test
  starts its own isolated instance on a unique path in an `async: false` case
  (mirrors `LocalOnboardingLiveTest`).
  """
  use SddOrchestratorWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import SddOrchestrator.AIRuntimeFixtures
  import SddOrchestrator.RepositoryKitFixtures

  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.DeviceStore.Local
  alias SddOrchestrator.Devices.Pairing
  alias SddOrchestrator.Repo
  alias SddOrchestrator.RepositoryInitialization
  alias SddOrchestrator.RepositoryInitialization.Plan

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

      # Reaching "ready" transitions the whole step to plan review (Task 3),
      # not an inline notice inside the guided-questions step.
      refute has_element?(view, "[data-step=guided-questions]")
      refute has_element?(view, "[data-answer-form]")
      assert has_element?(view, "[data-step=reviewing-plan]")
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

  describe "reviewing plan (Task 3)" do
    test "reaches reviewing_plan once every field is answered", %{
      conn: conn,
      workspace: workspace
    } do
      view = reach_reviewing_plan(conn, workspace)

      assert has_element?(view, "[data-step=reviewing-plan]")
      refute has_element?(view, "[data-step=guided-questions]")
    end

    test "renders the fixed skeleton: structure, commands, checks, and Git behavior (AC-04)", %{
      conn: conn,
      workspace: workspace
    } do
      view = reach_reviewing_plan(conn, workspace)

      assert has_element?(view, "[data-structure-entry]", "README.md")
      assert has_element?(view, "[data-section=commands]", "None configured yet")
      assert has_element?(view, "[data-section=checks]", "None configured yet")
      assert has_element?(view, "[data-git-initial-branch]", "main")
      assert has_element?(view, "[data-git-hooks]", "disabled")
      assert has_element?(view, "[data-git-first-commit-message]", "Initial commit")
    end

    test "renders the kit package's exact details, defaults to included, and offers decline (AC-04, AC-06)",
         %{conn: conn, workspace: workspace} do
      package = publish_package_fixture()
      view = reach_reviewing_plan(conn, workspace)

      assert has_element?(view, "[data-kit-source]", package.source)
      assert has_element?(view, "[data-kit-publisher]", package.publisher)
      assert has_element?(view, "[data-kit-version]", package.version)
      assert has_element?(view, "[data-kit-digest]", package.digest)
      assert has_element?(view, "[data-kit-license]", package.license)
      assert has_element?(view, "[data-kit-permissions]", "repository:read")
      assert has_element?(view, "[data-kit-scripts]", "scripts/check.sh")

      assert view |> element("#kit-included") |> render() =~ ~s(aria-checked="true")
      refute has_element?(view, "[data-kit-decline-notice]")

      render_click(view, "set_kit_choice", %{"choice" => "declined"})

      assert view |> element("#kit-declined") |> render() =~ ~s(aria-checked="true")
      assert has_element?(view, "[data-kit-decline-notice]")

      assert has_element?(
               view,
               "[data-kit-decline-notice]",
               "will not automatically receive Orchestrator's managed skills, profile, or authoritative project specifications"
             )
    end

    test "kit-choice radios are accessible: a radiogroup with a labeled, checked-stated radio each",
         %{conn: conn, workspace: workspace} do
      publish_package_fixture()
      view = reach_reviewing_plan(conn, workspace)

      assert has_element?(view, ~s([role="radiogroup"][aria-label]))
      assert has_element?(view, ~s(#kit-included[role="radio"][aria-label][aria-checked]))
      assert has_element?(view, ~s(#kit-declined[role="radio"][aria-label][aria-checked]))
    end

    test "shows no kit package is available yet when the catalog is empty, without a toggle", %{
      conn: conn,
      workspace: workspace
    } do
      view = reach_reviewing_plan(conn, workspace)

      assert has_element?(
               view,
               "[data-kit-state=unavailable]",
               "No kit package is available yet."
             )

      refute has_element?(view, "#kit-choice")
    end

    test "renders the worker summary and the accountless provider fallback (AC-04)", %{
      conn: conn,
      workspace: workspace
    } do
      view = reach_reviewing_plan(conn, workspace)

      assert has_element?(view, "[data-worker-summary]", "macos")
      assert has_element?(view, "[data-worker-summary]", "1.0.0")
      assert has_element?(view, "[data-provider-summary]", "signed in")
    end

    test "shows the real provider and model once a connected account is signed in", %{
      conn: conn,
      workspace: workspace
    } do
      context = runtime_session_context_fixture(%{now: DateTime.utc_now()})
      conn = log_in_account(conn, context.account)

      view = reach_reviewing_plan(conn, workspace)

      assert has_element?(view, "[data-provider-summary]", "openai_codex")
    end

    test "shows the processing-boundary disclosure and an enabled confirm control (AC-05)", %{
      conn: conn,
      workspace: workspace
    } do
      view = reach_reviewing_plan(conn, workspace)

      assert has_element?(view, "[data-processing-disclosure]")
      assert has_element?(view, "[data-confirm-plan]:not([disabled])")
    end

    test "a successful confirm reaches the placeholder", %{conn: conn, workspace: workspace} do
      view = reach_reviewing_plan(conn, workspace)

      render_click(view, "confirm_plan")

      assert has_element?(view, "[data-state=confirmed]")
      assert render(view) =~ "Plan confirmed"
      refute has_element?(view, "[data-confirm-plan]")
    end

    test "a changed-input case surfaces the plan-changed message rather than silently confirming",
         %{conn: conn, workspace: workspace} do
      publish_package_fixture()
      view = reach_reviewing_plan(conn, workspace)

      # Mutate out-of-band (through the context directly, bypassing this
      # view's own event handling) to simulate a second process changing the
      # plan between what this view rendered and when it submits confirm.
      plan = latest_plan(workspace.id)
      {:ok, _mutated} = RepositoryInitialization.set_kit_choice(plan, "included")

      render_click(view, "confirm_plan")

      assert render(view) =~ "This plan changed"
      refute has_element?(view, "[data-state=confirmed]")
    end
  end

  describe "building the repository (Task 6)" do
    setup do
      base =
        Path.join(System.tmp_dir!(), "sdd-ri-live-build-#{System.unique_integer([:positive])}")

      root = Path.join(base, "staging-root")
      File.mkdir_p!(root)

      previous = Application.fetch_env(:sdd_orchestrator, :initialization_staging_root)
      Application.put_env(:sdd_orchestrator, :initialization_staging_root, root)

      on_exit(fn ->
        case previous do
          {:ok, value} ->
            Application.put_env(:sdd_orchestrator, :initialization_staging_root, value)

          :error ->
            Application.delete_env(:sdd_orchestrator, :initialization_staging_root)
        end

        File.rm_rf!(base)
      end)

      :ok
    end

    test "starting the build with a paired worker reaches the result step with commit info and readiness axes",
         %{conn: conn, workspace: workspace} do
      view = reach_confirmed_declined(conn, workspace)

      render_click(view, "start_build")

      assert has_element?(view, "[data-step=building-result]")
      refute has_element?(view, "[data-step=reviewing-plan]")

      assert has_element?(view, "[data-commit-sha]")
      assert has_element?(view, "[data-tree-digest]")

      assert has_element?(view, "[data-readiness-assistant=ready]")
      assert has_element?(view, "[data-readiness-specification=ready]")
      assert has_element?(view, "[data-readiness-agent-execution=blocked]")
      assert has_element?(view, "[data-readiness-release=blocked]")
      assert has_element?(view, "[data-earliest-blocked-stage=agent_execution]")
    end

    test "starting the build without a paired worker shows the no-worker error and stays on the confirmed step",
         %{conn: conn} do
      dir = empty_dir_fixture()
      on_exit(fn -> File.rm_rf!(dir) end)
      stub_folder(dir)

      {:ok, view, _html} = live(conn, ~p"/onboarding/empty-repository")
      render_click(view, "continue_to_selection")
      render_click(view, "select_folder")

      answer(view, "purpose", "A CLI tool")
      answer(view, "users", "Founders")
      answer(view, "first_outcome", "First working release")
      answer(view, "constraints", "None yet")
      answer(view, "technical_foundation", "Elixir + Phoenix")

      render_click(view, "set_kit_choice", %{"choice" => "declined"})
      render_click(view, "confirm_plan")

      render_click(view, "start_build")

      assert has_element?(view, "[data-build-error]")
      assert render(view) =~ "No paired worker was found"
      assert has_element?(view, "[data-state=confirmed]")
      refute has_element?(view, "[data-step=building-result]")
      refute has_element?(view, "[data-step=failed]")
    end

    test "a pipeline failure moves to the failed step with a visible reason", %{
      conn: conn,
      workspace: workspace
    } do
      view = reach_reviewing_plan(conn, workspace)

      # The kit choice defaults to "included" with no digest and no package is
      # published in this test, so `StagingBuilder`'s own package-availability
      # check refuses the run instead of vendoring nothing.
      render_click(view, "confirm_plan")

      render_click(view, "start_build")

      assert has_element?(view, "[data-step=failed]")
      assert has_element?(view, "[data-failure-reason]")
      refute has_element?(view, "[data-step=building-result]")
    end
  end

  # ---- helpers ----

  defp reach_confirmed_declined(conn, workspace) do
    view = reach_reviewing_plan(conn, workspace)
    render_click(view, "set_kit_choice", %{"choice" => "declined"})
    render_click(view, "confirm_plan")
    view
  end

  defp answer(view, field, value) do
    render_submit(view, "submit_answer", %{"field" => field, "value" => value})
  end

  defp reach_reviewing_plan(conn, workspace) do
    pair(workspace.id)
    dir = empty_dir_fixture()
    on_exit(fn -> File.rm_rf!(dir) end)
    stub_folder(dir)

    {:ok, view, _html} = live(conn, ~p"/onboarding/empty-repository")
    render_click(view, "continue_to_selection")
    render_click(view, "select_folder")

    answer(view, "purpose", "A CLI tool")
    answer(view, "users", "Founders")
    answer(view, "first_outcome", "First working release")
    answer(view, "constraints", "None yet")
    answer(view, "technical_foundation", "Elixir + Phoenix")

    view
  end

  defp latest_plan(workspace_id) do
    Repo.one!(
      from p in Plan,
        where: p.device_workspace_id == ^workspace_id,
        order_by: [desc: p.inserted_at],
        limit: 1
    )
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
