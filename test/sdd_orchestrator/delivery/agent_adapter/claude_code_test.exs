defmodule SddOrchestrator.Delivery.AgentAdapter.ClaudeCodeTest do
  @moduledoc """
  Task 6 proof: the Claude Code agent adapter.

  Covers [AC-09] — the installed agent version is checked before launch, the
  agent runs in the proven directory with only the projected input and
  allowlisted environment, and its output is observed as normalized events
  including a resumed or newly started thread.

  Every scenario except the real-CLI guarded ones runs against a
  deterministic scripted `claude` stand-in
  (`SddOrchestrator.ClaudeCodeCliFixture`) rather than the real subprocess,
  so this suite is fast, offline, and free — the real installed CLI is only
  exercised once, to prove the fixture's assumptions still hold against it.
  """

  # `:agent_executable` is process-wide `Application` env, and this suite's
  # own tests (and `CodexTest`'s) mutate it repeatedly — `async: true` here
  # would race concurrently-running tests over that same global key.
  use ExUnit.Case, async: false

  alias SddOrchestrator.ClaudeCodeCliFixture, as: Fixture
  alias SddOrchestrator.Delivery.AgentAdapter
  alias SddOrchestrator.Delivery.AgentAdapter.ClaudeCode
  alias SddOrchestrator.Delivery.Worker.Workspace
  alias SddOrchestrator.DeliveryProtocolFixtures

  setup do
    previous = Application.fetch_env(:sdd_orchestrator, :agent_executable)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:sdd_orchestrator, :agent_executable, value)
        :error -> Application.delete_env(:sdd_orchestrator, :agent_executable)
      end
    end)

    :ok
  end

  describe "installed_version/0" do
    test "a genuine claude executable reports this adapter's own output-schema version" do
      configure(Fixture.version_only_script("9.9.9 (Claude Code)"))
      assert ClaudeCode.installed_version() == {:ok, "1.0.0"}
    end

    test "an executable answering --version with an unrecognizable shape is refused" do
      configure(Fixture.version_only_script("not a version"))
      assert ClaudeCode.installed_version() == {:error, :agent_unavailable}
    end

    test "a --version exiting nonzero is refused" do
      configure(Fixture.version_only_script("boom", exit_status: 1))
      assert ClaudeCode.installed_version() == {:error, :agent_unavailable}
    end

    test "a missing executable is refused" do
      configure(missing_executable())
      assert ClaudeCode.installed_version() == {:error, :agent_unavailable}
    end

    if System.find_executable("claude") do
      test "the real installed claude CLI is recognized" do
        Application.delete_env(:sdd_orchestrator, :agent_executable)
        assert ClaudeCode.installed_version() == {:ok, "1.0.0"}
      end
    else
      test "the real CLI proof needs a claude executable on PATH" do
        flunk("environment blocker: no claude executable, so the real CLI cannot be proven")
      end
    end
  end

  describe "start/1 and observe/1 over a scripted subprocess" do
    test "a new session decodes streamed progress and the final result, in order" do
      lines = [
        %{"type" => "system", "subtype" => "init", "session_id" => "thr_new"},
        %{
          "type" => "assistant",
          "message" => %{"content" => [%{"type" => "text", "text" => "Working on it"}]},
          "timestamp" => "2026-08-07T00:00:00Z"
        },
        %{"type" => "result", "is_error" => false, "result" => "All done"}
      ]

      configure(Fixture.streaming_script(lines))

      assert {:ok, handle} = ClaudeCode.start(input())
      refute handle.resumed?
      assert handle.thread_ref == "thr_new"

      assert {:ok, events} = drain_all(handle)
      assert [progress, final] = events
      assert progress["type"] == "progress"
      assert progress["occurred_at"] == "2026-08-07T00:00:00Z"
      assert progress["payload"]["summary"] == "Working on it"
      assert final["type"] == "progress"
      assert final["payload"]["summary"] == "All done"

      assert ClaudeCode.observe(handle) == {:error, :agent_exited}
    end

    test "a resumed session is reported as resumed with the same thread reference" do
      lines = [
        %{"type" => "system", "subtype" => "init", "session_id" => "thr_existing"},
        %{"type" => "result", "is_error" => false, "result" => "continued"}
      ]

      configure(Fixture.streaming_script(lines))

      assert {:ok, handle} = ClaudeCode.start(input(thread_ref: "thr_existing"))
      assert handle.resumed?
      assert handle.thread_ref == "thr_existing"
    end

    test "an unresumable session is refused so the boundary falls back to a new thread" do
      lines = [
        %{
          "type" => "result",
          "is_error" => true,
          "subtype" => "error_during_execution",
          "errors" => ["No conversation found with session ID: thr_gone"]
        }
      ]

      configure(Fixture.streaming_script(lines, exit_status: 1))

      assert ClaudeCode.start(input(thread_ref: "thr_gone")) == {:error, :thread_not_found}
    end

    test "a turn that fails after a real session started is decoded as a failed event" do
      lines = [
        %{"type" => "system", "subtype" => "init", "session_id" => "thr_fails_midway"},
        %{
          "type" => "result",
          "is_error" => true,
          "subtype" => "error_during_execution",
          "errors" => ["provider request failed"]
        }
      ]

      configure(Fixture.streaming_script(lines))

      assert {:ok, handle} = ClaudeCode.start(input())
      assert {:ok, [event]} = drain_all(handle)
      assert event["type"] == "failed"
      assert event["payload"]["reason"] == "error_during_execution"
      assert event["payload"]["summary"] == "provider request failed"
    end

    test "a process that exits nonzero without ever starting a session is a launch failure" do
      configure(Fixture.streaming_script([], exit_status: 1))
      assert ClaudeCode.start(input()) == {:error, :agent_launch_failed}
    end

    test "a missing executable at launch time is refused" do
      configure(missing_executable())
      assert ClaudeCode.start(input()) == {:error, :agent_unavailable}
    end

    test "the subprocess receives only the allowlisted environment, never the worker's own" do
      System.put_env("SDD_TEST_LEAK_VAR", "should-not-be-visible")
      on_exit(fn -> System.delete_env("SDD_TEST_LEAK_VAR") end)

      configure(Fixture.environment_probe_script("SDD_TEST_LEAK_VAR", "HOME"))

      assert {:ok, handle} = ClaudeCode.start(input())
      assert {:ok, [progress, _result]} = drain_all(handle)
      assert progress["payload"]["summary"] == "leak=absent keep=present"
    end

    test "the subprocess is launched only in the projected working directory" do
      marker = "claude-cwd-#{System.unique_integer([:positive])}"
      working_directory = Path.join(System.tmp_dir!(), marker)
      File.mkdir_p!(working_directory)
      on_exit(fn -> File.rm_rf!(working_directory) end)

      configure(Fixture.cwd_probe_script())

      assert {:ok, handle} =
               ClaudeCode.start(
                 input(agent_input: agent_input(working_directory: working_directory))
               )

      assert {:ok, [progress, _result]} = drain_all(handle)
      assert progress["payload"]["summary"] =~ marker
    end

    test "a stop kills the underlying OS process, not just the GenServer" do
      pid_file =
        Path.join(System.tmp_dir!(), "claude-longrun-#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm(pid_file) end)

      configure(Fixture.long_running_script(pid_file))

      assert {:ok, handle} = ClaudeCode.start(input())
      session = handle.reference

      os_pid = wait_for_pid_file(pid_file)

      # `GatewayConnection.stop_launch/1` unlinks before stopping so its own
      # EXIT signal is not misread as the agent crashing — mirrored here for
      # the same reason.
      Process.unlink(session)
      assert :ok = GenServer.stop(session, :shutdown, 5_000)

      assert_os_process_dead(os_pid)
    end

    test "a stop after the session already exited on its own does not error" do
      lines = [
        %{"type" => "system", "subtype" => "init", "session_id" => "thr_already_done"},
        %{"type" => "result", "is_error" => false, "result" => "done"}
      ]

      configure(Fixture.streaming_script(lines))

      assert {:ok, handle} = ClaudeCode.start(input())
      session = handle.reference

      # Drains until `observe/1` itself reports `:agent_exited`, so
      # `status` is genuinely `{:exited, _}` (not `:running`) by the time
      # `terminate/2` runs below — the branch this test means to exercise.
      assert {:ok, _events} = drain_all(handle)

      Process.unlink(session)
      assert :ok = GenServer.stop(session, :shutdown, 5_000)
    end
  end

  describe "composed through the shared AgentAdapter boundary" do
    setup do
      previous = Application.fetch_env(:sdd_orchestrator, :worker_workspace_root)

      root =
        Path.join(
          System.tmp_dir!(),
          "claude-adapter-boundary-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(root)
      Application.put_env(:sdd_orchestrator, :worker_workspace_root, root)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:sdd_orchestrator, :worker_workspace_root, value)
          :error -> Application.delete_env(:sdd_orchestrator, :worker_workspace_root)
        end

        File.rm_rf!(root)
      end)

      :ok
    end

    test "a full launch and observe cycle produces protocol-valid envelopes in order" do
      manifest = DeliveryProtocolFixtures.manifest()
      {:ok, _workspace} = Workspace.prepare(manifest)
      {:ok, directory} = Workspace.working_directory(manifest)

      lines = [
        %{"type" => "system", "subtype" => "init", "session_id" => "thr_boundary"},
        %{
          "type" => "assistant",
          "message" => %{"content" => [%{"type" => "text", "text" => "Implementing the change"}]},
          "timestamp" => "2026-08-07T00:00:00Z"
        },
        %{"type" => "result", "is_error" => false, "result" => "Implemented"}
      ]

      configure(Fixture.streaming_script(lines))

      assert {:ok, launch} = AgentAdapter.launch(manifest, directory, adapter: ClaudeCode)
      assert launch.agent_version == "1.0.0"
      assert launch.thread_start == :new
      assert launch.thread_ref == "thr_boundary"

      # `launch/3` only waits for the initial system/init event, not the
      # rest of this tiny fixture's output, so `observe/2` gets a moment to
      # actually see it arrive before draining once.
      Process.sleep(50)

      assert {:ok, observation} =
               AgentAdapter.observe(launch,
                 adapter: ClaudeCode,
                 command_id: DeliveryProtocolFixtures.command_id(),
                 fence_token: 1
               )

      assert observation.dropped == []
      assert [progress, final] = observation.events
      assert progress["event_type"] == "progress"
      assert progress["sequence"] == 1
      assert progress["source"] == "agent"
      assert final["event_type"] == "progress"
      assert final["sequence"] == 2
      assert observation.last_sequence == 2
      assert observation.terminal == nil
    end
  end

  # --- helpers -------------------------------------------------------------

  # `observe/1` drains its buffer on every call and never re-delivers, so
  # polling it directly and discarding intermediate results would lose
  # events — this accumulates every call's events until the process reports
  # `:agent_exited` (nothing more, ever) or the attempt budget runs out.
  defp drain_all(handle, acc \\ [], attempts \\ 100) do
    case ClaudeCode.observe(handle) do
      {:error, :agent_exited} ->
        {:ok, acc}

      {:ok, events} when attempts <= 0 ->
        {:ok, acc ++ events}

      {:ok, events} ->
        Process.sleep(10)
        drain_all(handle, acc ++ events, attempts - 1)
    end
  end

  # The fixture writes its own OS pid to this file as (nearly) its first
  # action, but the port's `{:data, _}` delivery to this test process is
  # still async relative to that write landing on disk, so this polls
  # briefly rather than reading once.
  defp wait_for_pid_file(path, attempts \\ 200) do
    case File.read(path) do
      {:ok, content} when content != "" ->
        String.trim(content)

      _not_yet_written when attempts > 0 ->
        Process.sleep(10)
        wait_for_pid_file(path, attempts - 1)

      _never_written ->
        flunk("environment blocker: fixture never wrote its OS pid to #{path}")
    end
  end

  # Signal delivery and reaping are not synchronous with `GenServer.stop/3`
  # returning, so this polls `kill -0` briefly rather than asserting
  # instantly — a nonzero exit (ESRCH) is the standard, portable liveness
  # probe.
  defp assert_os_process_dead(pid_string, attempts \\ 100) do
    case System.cmd("kill", ["-0", pid_string], stderr_to_stdout: true) do
      {_output, 0} when attempts > 0 ->
        Process.sleep(10)
        assert_os_process_dead(pid_string, attempts - 1)

      {_output, 0} ->
        flunk("OS process #{pid_string} is still alive after stop")

      {_output, _nonzero_exit} ->
        :ok
    end
  end

  defp configure(path), do: Application.put_env(:sdd_orchestrator, :agent_executable, path)

  defp missing_executable,
    do: Path.join(System.tmp_dir!(), "no-such-claude-#{System.unique_integer([:positive])}")

  defp input(overrides \\ []) do
    %{
      agent_input: Keyword.get(overrides, :agent_input, agent_input()),
      environment: AgentAdapter.environment(),
      thread_ref: Keyword.get(overrides, :thread_ref)
    }
  end

  defp agent_input(overrides \\ []) do
    overrides = Map.new(overrides)

    %{
      "project_id" => "prj_01HZX0000000000000000001",
      "feature_id" => "ftr_01HZX0000000000000000002",
      "run_id" => "run_01HZX0000000000000000003",
      "attempt_number" => 1,
      "approved_slice" => "07-guided-specification-delivery",
      "starting_revision_id" => "rev_01HZX0000000000000000007",
      "starting_revision_digest" => String.duplicate("a1", 32),
      "effective_revision_id" => "rev_01HZX0000000000000000007",
      "effective_revision_digest" => String.duplicate("a1", 32),
      "manifest_digest" => String.duplicate("a1", 32),
      "target_branch" => "sdd/feature/ftr-0002/run-0003",
      "required_checks" => [%{"name" => "test", "command" => "mix test"}],
      "continuation" => %{"reason" => "initial", "prior_attempt_number" => nil},
      "agent_ref" => %{"provider_ref" => "claude_code"},
      "working_directory" => Map.get(overrides, :working_directory, System.tmp_dir!())
    }
  end
end
