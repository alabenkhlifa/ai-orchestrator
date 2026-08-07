defmodule SddOrchestrator.Delivery.AgentAdapter.CodexTest do
  @moduledoc """
  Task 7 proof: the Codex agent adapter.

  Covers [AC-10] — the same version check, launch boundary, environment
  allowlist, and normalized observation hold for Codex as for Claude Code,
  and the choice of agent changes nothing the control plane observes beyond
  the recorded agent reference.

  Every scenario except the real-CLI guarded ones runs against a
  deterministic scripted `codex` stand-in (`SddOrchestrator.CodexCliFixture`)
  rather than the real subprocess, mirroring
  `SddOrchestrator.Delivery.AgentAdapter.ClaudeCodeTest`.
  """

  # `:agent_executable` is process-wide `Application` env, and this suite's
  # own tests (and `ClaudeCodeTest`'s) mutate it repeatedly — `async: true`
  # here would race concurrently-running tests over that same global key.
  use ExUnit.Case, async: false

  alias SddOrchestrator.CodexCliFixture, as: Fixture
  alias SddOrchestrator.Delivery.AgentAdapter
  alias SddOrchestrator.Delivery.AgentAdapter.Codex
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
    test "a genuine codex executable reports this adapter's own output-schema version" do
      configure(Fixture.version_only_script("codex-cli 9.9.9"))
      assert Codex.installed_version() == {:ok, "1.0.0"}
    end

    test "an executable answering --version with an unrecognizable shape is refused" do
      configure(Fixture.version_only_script("not a version"))
      assert Codex.installed_version() == {:error, :agent_unavailable}
    end

    test "a --version exiting nonzero is refused" do
      configure(Fixture.version_only_script("boom", exit_status: 1))
      assert Codex.installed_version() == {:error, :agent_unavailable}
    end

    test "a missing executable is refused" do
      configure(missing_executable())
      assert Codex.installed_version() == {:error, :agent_unavailable}
    end

    if System.find_executable("codex") do
      test "the real installed codex CLI is recognized" do
        Application.delete_env(:sdd_orchestrator, :agent_executable)
        assert Codex.installed_version() == {:ok, "1.0.0"}
      end
    else
      test "the real CLI proof needs a codex executable on PATH" do
        flunk("environment blocker: no codex executable, so the real CLI cannot be proven")
      end
    end
  end

  describe "start/1 and observe/1 over a scripted subprocess" do
    test "a new session decodes streamed progress and the final turn, in order" do
      lines = [
        %{"type" => "thread.started", "thread_id" => "thr_new"},
        %{"type" => "turn.started"},
        %{
          "type" => "item.completed",
          "item" => %{"id" => "item_0", "type" => "agent_message", "text" => "Working on it"}
        },
        %{"type" => "turn.completed", "usage" => %{}}
      ]

      configure(Fixture.streaming_script(lines))

      assert {:ok, handle} = Codex.start(input())
      refute handle.resumed?
      assert handle.thread_ref == "thr_new"

      assert {:ok, events} = drain_all(handle)
      assert [progress, final] = events
      assert progress["type"] == "progress"
      assert progress["payload"]["summary"] == "Working on it"
      assert final["type"] == "progress"
      assert final["payload"]["summary"] == "Turn completed."

      assert Codex.observe(handle) == {:error, :agent_exited}
    end

    test "a resumed session is reported as resumed with the same thread reference" do
      lines = [
        %{"type" => "thread.started", "thread_id" => "thr_existing"},
        %{"type" => "turn.completed", "usage" => %{}}
      ]

      configure(Fixture.streaming_script(lines))

      assert {:ok, handle} = Codex.start(input(thread_ref: "thr_existing"))
      assert handle.resumed?
      assert handle.thread_ref == "thr_existing"
    end

    test "an unresumable session is refused so the boundary falls back to a new thread" do
      # Confirmed live: an unresolvable `codex exec resume` prints a
      # plain-text error to inherited stderr (nothing on stdout) and exits
      # nonzero without ever emitting `thread.started`.
      configure(Fixture.streaming_script([], exit_status: 1))

      assert Codex.start(input(thread_ref: "thr_gone")) == {:error, :thread_not_found}
    end

    test "a process that dies mid-turn without completing is decoded as a failed event" do
      lines = [%{"type" => "thread.started", "thread_id" => "thr_dies_midway"}]
      configure(Fixture.streaming_script(lines, exit_status: 1))

      assert {:ok, handle} = Codex.start(input())
      assert {:ok, [event]} = drain_all(handle)
      assert event["type"] == "failed"
      assert event["payload"]["reason"] == "agent_exited"
    end

    test "a process that exits nonzero without ever starting a thread is a launch failure" do
      configure(Fixture.streaming_script([], exit_status: 1))
      assert Codex.start(input()) == {:error, :agent_launch_failed}
    end

    test "a missing executable at launch time is refused" do
      configure(missing_executable())
      assert Codex.start(input()) == {:error, :agent_unavailable}
    end

    test "the subprocess receives only the allowlisted environment, never the worker's own" do
      System.put_env("SDD_TEST_LEAK_VAR", "should-not-be-visible")
      on_exit(fn -> System.delete_env("SDD_TEST_LEAK_VAR") end)

      configure(Fixture.environment_probe_script("SDD_TEST_LEAK_VAR", "HOME"))

      assert {:ok, handle} = Codex.start(input())
      assert {:ok, [progress, _final]} = drain_all(handle)
      assert progress["payload"]["summary"] == "leak=absent keep=present"
    end

    test "the subprocess is launched only in the projected working directory" do
      marker = "codex-cwd-#{System.unique_integer([:positive])}"
      working_directory = Path.join(System.tmp_dir!(), marker)
      File.mkdir_p!(working_directory)
      on_exit(fn -> File.rm_rf!(working_directory) end)

      configure(Fixture.cwd_probe_script())

      assert {:ok, handle} =
               Codex.start(input(agent_input: agent_input(working_directory: working_directory)))

      assert {:ok, [progress, _final]} = drain_all(handle)
      assert progress["payload"]["summary"] =~ marker
    end

    test "the subprocess never blocks on stdin even though codex exec would read it" do
      configure(Fixture.stdin_sensitive_script())

      assert {:ok, handle} = Codex.start(input())
      assert handle.thread_ref == "thr_stdin_sensitive"
    end
  end

  describe "composed through the shared AgentAdapter boundary" do
    setup do
      previous = Application.fetch_env(:sdd_orchestrator, :worker_workspace_root)

      root =
        Path.join(
          System.tmp_dir!(),
          "codex-adapter-boundary-#{System.unique_integer([:positive])}"
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
        %{"type" => "thread.started", "thread_id" => "thr_boundary"},
        %{
          "type" => "item.completed",
          "item" => %{
            "id" => "item_0",
            "type" => "agent_message",
            "text" => "Implementing the change"
          }
        },
        %{"type" => "turn.completed", "usage" => %{}}
      ]

      configure(Fixture.streaming_script(lines))

      assert {:ok, launch} = AgentAdapter.launch(manifest, directory, adapter: Codex)
      assert launch.agent_version == "1.0.0"
      assert launch.thread_start == :new
      assert launch.thread_ref == "thr_boundary"

      # `launch/3` only waits for `thread.started`, not the rest of this
      # tiny fixture's output, so `observe/2` gets a moment to actually see
      # it arrive before draining once.
      Process.sleep(50)

      assert {:ok, observation} =
               AgentAdapter.observe(launch,
                 adapter: Codex,
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

    test "the choice of agent changes nothing the control plane observes beyond the recorded agent reference" do
      manifest = DeliveryProtocolFixtures.manifest()
      {:ok, _workspace} = Workspace.prepare(manifest)
      {:ok, directory} = Workspace.working_directory(manifest)

      lines = [
        %{"type" => "thread.started", "thread_id" => "thr_parity"},
        %{
          "type" => "item.completed",
          "item" => %{
            "id" => "item_0",
            "type" => "agent_message",
            "text" => "Same shape as Claude Code"
          }
        },
        %{"type" => "turn.completed", "usage" => %{}}
      ]

      configure(Fixture.streaming_script(lines))

      assert {:ok, launch} = AgentAdapter.launch(manifest, directory, adapter: Codex)
      Process.sleep(50)

      assert {:ok, observation} =
               AgentAdapter.observe(launch,
                 adapter: Codex,
                 command_id: DeliveryProtocolFixtures.command_id(),
                 fence_token: 1
               )

      [progress, _final] = observation.events
      envelope_keys = progress |> Map.keys() |> Enum.sort()

      assert envelope_keys == [
               "attempt_number",
               "command_id",
               "event_id",
               "event_type",
               "fence_token",
               "occurred_at",
               "payload",
               "protocol_version",
               "run_id",
               "sequence",
               "source",
               "type"
             ]

      assert progress["source"] == "agent"
    end
  end

  # --- helpers -------------------------------------------------------------

  # `observe/1` drains its buffer on every call and never re-delivers, so
  # polling it directly and discarding intermediate results would lose
  # events — this accumulates every call's events until the process reports
  # `:agent_exited` (nothing more, ever) or the attempt budget runs out.
  defp drain_all(handle, acc \\ [], attempts \\ 100) do
    case Codex.observe(handle) do
      {:error, :agent_exited} ->
        {:ok, acc}

      {:ok, events} when attempts <= 0 ->
        {:ok, acc ++ events}

      {:ok, events} ->
        Process.sleep(10)
        drain_all(handle, acc ++ events, attempts - 1)
    end
  end

  defp configure(path), do: Application.put_env(:sdd_orchestrator, :agent_executable, path)

  defp missing_executable,
    do: Path.join(System.tmp_dir!(), "no-such-codex-#{System.unique_integer([:positive])}")

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
      "agent_ref" => %{"provider_ref" => "codex"},
      "working_directory" => Map.get(overrides, :working_directory, System.tmp_dir!())
    }
  end
end
