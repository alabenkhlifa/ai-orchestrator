defmodule SddOrchestrator.Worker.CommandLifecycleEnvelopeSource do
  @moduledoc """
  Supplies the protocol envelope a durable command is delivered as, scoped to
  `SddOrchestrator.Worker.CommandLifecycleTest`.

  Mirrors the pattern `SddOrchestrator.Worker.CommandHandlingEnvelopeSource`
  and its siblings already establish, defined locally so this file's
  `mix test` invocation never depends on another test file being compiled
  alongside it.
  """
  @behaviour SddOrchestrator.Delivery.CommandTransport.EnvelopeSource

  @key {__MODULE__, :envelopes}

  def install do
    original = Application.get_env(:sdd_orchestrator, :command_envelope_source)
    Application.put_env(:sdd_orchestrator, :command_envelope_source, __MODULE__)
    Process.put(@key, %{})

    fn -> Application.put_env(:sdd_orchestrator, :command_envelope_source, original) end
  end

  def script(command_id, envelope) do
    Process.put(@key, Map.put(Process.get(@key, %{}), command_id, envelope))
    envelope
  end

  @impl true
  def envelope(command) do
    case Map.fetch(Process.get(@key, %{}), command.id) do
      {:ok, envelope} -> {:ok, envelope}
      :error -> {:error, :envelope_unavailable}
    end
  end
end

defmodule SddOrchestrator.Worker.CommandLifecycleTest do
  @moduledoc """
  Task 11 proof: cancel, resume, retry, and reconcile.

  Covers [AC-15] — the worker honors every capability it announces during
  protocol negotiation: `cancel` stops a running agent and durably releases
  its lease and lock; `resume` and `retry` execute from the manifest, and
  when a provider thread is available they resume it rather than starting
  fresh; `reconcile` answers with the worker's own authoritative attempt
  snapshot, both on explicit request and unconditionally on every (re)join.

  Runs over the real gateway (real `Bandit`, real
  `SddOrchestratorWeb.WorkerChannel`, real `CommandOutbox`/`Transport`, real
  `SddOrchestrator.Worker.GatewayConnection`) against a scripted `claude`
  stand-in (`SddOrchestrator.ClaudeCodeCliFixture` or a dedicated inline
  script), matching the pattern `RequiredCheckRunnerTest` and
  `AgentEventDeliveryTest` already establish. The lighter, no-harness
  `CommandHandler.handle_command/3` checks reuse `CommandHandlingTest`'s own
  established pattern for decisions that do not need a real process.
  """

  use SddOrchestrator.DataCase, async: false

  import SddOrchestrator.AccountsFixtures
  import SddOrchestrator.ProjectsFixtures

  alias Phoenix.PubSub
  alias SddOrchestrator.Accounts.DeviceWorkspace
  alias SddOrchestrator.Delivery.AgentAdapter
  alias SddOrchestrator.Delivery.CommandOutbox
  alias SddOrchestrator.Delivery.CommandTransport.Channel, as: Transport
  alias SddOrchestrator.Delivery.ExecutionManifest
  alias SddOrchestrator.Delivery.ProtocolCodec
  alias SddOrchestrator.Delivery.RunAttempt
  alias SddOrchestrator.Delivery.Worker.Workspace
  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.DeliveryProtocolFixtures
  alias SddOrchestrator.Devices.Pairing
  alias SddOrchestrator.Portability.HostedLocalRepositoryBindings
  alias SddOrchestrator.Projects.Project
  alias SddOrchestrator.Repo
  alias SddOrchestrator.Worker.CommandHandler
  alias SddOrchestrator.Worker.CommandLifecycleEnvelopeSource, as: EnvelopeSource
  alias SddOrchestrator.Worker.Configuration
  alias SddOrchestrator.Worker.GatewayConnection
  alias SddOrchestrator.Worker.RunState
  alias SddOrchestratorWeb.WorkerChannel

  # Fast enough to keep the suite quick, long enough that a slow CI tick
  # never races the assertions below.
  @observe_interval 30

  setup do
    previous_root = Application.fetch_env(:sdd_orchestrator, :worker_workspace_root)
    previous_adapter = Application.fetch_env(:sdd_orchestrator, :agent_adapter)
    previous_executable = Application.fetch_env(:sdd_orchestrator, :agent_executable)

    root =
      Path.join(
        System.tmp_dir!(),
        "sdd-command-lifecycle-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    Application.put_env(:sdd_orchestrator, :worker_workspace_root, root)
    Application.put_env(:sdd_orchestrator, :agent_adapter, AgentAdapter.ClaudeCode)

    on_exit(fn ->
      restore_env(:worker_workspace_root, previous_root)
      restore_env(:agent_adapter, previous_adapter)
      restore_env(:agent_executable, previous_executable)
      File.rm_rf!(root)
    end)

    on_exit(EnvelopeSource.install())

    bandit =
      start_supervised!(
        {Bandit, plug: SddOrchestratorWeb.Endpoint, scheme: :http, port: 0, startup_log: false}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    %{control_plane_address: "http://127.0.0.1:#{port}"}
  end

  describe "AC-15: cancel stops a running agent and releases the lease and lock" do
    test "the agent subprocess-owning session ends, the lock releases, and the lifecycle becomes canceled",
         %{control_plane_address: base} do
      %{project: project, feature: feature, run: run, credential: credential, worker: worker} =
        paired_and_bound_project()

      configure(sleepy_script())

      {command, envelope, _attempt} = enqueue_start_with_real_repository(project, feature, run)
      EnvelopeSource.script(command.id, envelope)

      :ok = PubSub.subscribe(SddOrchestrator.PubSub, WorkerChannel.topic(project.id))

      home = tmp_home()
      config = build_config(base, credential, project.id, worker.id)

      {:ok, pid} =
        GatewayConnection.start_link(config, home: home, observe_interval: @observe_interval)

      on_exit(fn -> stop_gateway(pid) end)

      wait_until(fn -> Transport.attached(project.id) != [] end)
      assert Transport.deliver(command) == :ok

      assert_receive {:worker_event, %{"event_type" => "workspace_ready"}}, 3_000
      assert_receive {:worker_heartbeat, %{"state" => "running"}}, 3_000

      assert_receive {:worker_event,
                      %{
                        "event_type" => "progress",
                        "payload" => %{"summary" => "still working"}
                      }},
                     3_000

      session_pid = launch_session_pid(pid)
      assert Process.alive?(session_pid)

      {cancel_command, cancel_envelope} = enqueue_cancel(project, feature, run)
      EnvelopeSource.script(cancel_command.id, cancel_envelope)

      assert Transport.deliver(cancel_command) == :ok
      wait_until(fn -> acknowledged?(cancel_command.id) end)

      assert {:ok, recorded} = CommandOutbox.fetch(cancel_command.id)
      assert recorded.result["status"] == "accepted"

      wait_until(fn ->
        match?({:ok, %{current: %{lifecycle: "canceled"}}}, RunState.load(home))
      end)

      refute Process.alive?(session_pid)

      {:ok, manifest} = ProtocolCodec.manifest(envelope)
      {:ok, workspace} = Workspace.prepare(manifest)
      refute File.exists?(Path.join(workspace, "run.lock"))

      refute_receive {:worker_event, %{"payload" => %{"summary" => "should never be observed"}}},
                     700
    end
  end

  describe "AC-15: resume and retry execute from the manifest and resume the provider thread" do
    test "a resume, then a retry, each receive their own recorded continuation and resume the prior provider thread",
         %{control_plane_address: base} do
      %{project: project, feature: feature, run: run, credential: credential, worker: worker} =
        paired_and_bound_project()

      configure(resume_probe_script())

      required_checks = [%{"name" => "noop", "command" => "true"}]
      revision = init_repository(project, feature, run, required_checks)

      {start_command, start_envelope, start_attempt} =
        enqueue_attempt(project, feature, run, revision,
          operation: "start",
          attempt_number: 1,
          fence_token: 1,
          continuation: %{"reason" => "initial", "prior_attempt_number" => nil},
          required_checks: required_checks
        )

      EnvelopeSource.script(start_command.id, start_envelope)

      :ok = PubSub.subscribe(SddOrchestrator.PubSub, WorkerChannel.topic(project.id))

      home = tmp_home()
      config = build_config(base, credential, project.id, worker.id)

      {:ok, pid} =
        GatewayConnection.start_link(config, home: home, observe_interval: @observe_interval)

      on_exit(fn -> stop_gateway(pid) end)

      wait_until(fn -> Transport.attached(project.id) != [] end)
      assert Transport.deliver(start_command) == :ok

      assert_receive {:worker_event, %{"event_type" => "workspace_ready"}}, 3_000

      assert_receive {:worker_event,
                      %{
                        "event_type" => "progress",
                        "attempt_number" => 1,
                        "payload" => %{"summary" => "resumed=none"}
                      }},
                     3_000

      wait_until(fn ->
        match?(
          {:ok, %{current: %{lifecycle: "verification_completed", attempt_number: 1}}},
          RunState.load(home)
        )
      end)

      assert {:ok, %{current: %{agent_thread_ref: original_thread_ref}}} = RunState.load(home)
      assert original_thread_ref == "thr_lifecycle_probe"

      supersede!(start_attempt)

      {resume_command, resume_envelope, resume_attempt} =
        enqueue_attempt(project, feature, run, revision,
          operation: "resume",
          attempt_number: 2,
          fence_token: 2,
          continuation: %{"reason" => "blocking_answer", "prior_attempt_number" => 1},
          required_checks: required_checks
        )

      EnvelopeSource.script(resume_command.id, resume_envelope)

      assert Transport.deliver(resume_command) == :ok

      assert_receive {:worker_event,
                      %{
                        "event_type" => "progress",
                        "attempt_number" => 2,
                        "payload" => %{"summary" => "resumed=thr_lifecycle_probe"}
                      }},
                     3_000

      wait_until(fn ->
        match?(
          {:ok, %{current: %{lifecycle: "verification_completed", attempt_number: 2}}},
          RunState.load(home)
        )
      end)

      assert {:ok, %{current: %{agent_thread_ref: resumed_thread_ref}}} = RunState.load(home)
      assert resumed_thread_ref == original_thread_ref

      supersede!(resume_attempt)

      {retry_command, retry_envelope, _retry_attempt} =
        enqueue_attempt(project, feature, run, revision,
          operation: "retry",
          attempt_number: 3,
          fence_token: 3,
          continuation: %{"reason" => "manual_retry", "prior_attempt_number" => 2},
          required_checks: required_checks
        )

      EnvelopeSource.script(retry_command.id, retry_envelope)

      assert Transport.deliver(retry_command) == :ok

      assert_receive {:worker_event,
                      %{
                        "event_type" => "progress",
                        "attempt_number" => 3,
                        "payload" => %{"summary" => "resumed=thr_lifecycle_probe"}
                      }},
                     3_000

      wait_until(fn ->
        match?(
          {:ok, %{current: %{lifecycle: "verification_completed", attempt_number: 3}}},
          RunState.load(home)
        )
      end)

      assert {:ok, %{current: %{agent_thread_ref: retried_thread_ref}}} = RunState.load(home)
      assert retried_thread_ref == original_thread_ref
    end
  end

  describe "AC-15: reconcile answers with the worker's authoritative attempt snapshot" do
    test "an explicit reconcile command is answered with a snapshot matching RunState.current exactly",
         %{control_plane_address: base} do
      %{project: project, feature: feature, run: run, credential: credential, worker: worker} =
        paired_and_bound_project()

      configure(stable_two_step_script())

      {command, envelope, _attempt} = enqueue_start_with_real_repository(project, feature, run)
      EnvelopeSource.script(command.id, envelope)

      :ok = PubSub.subscribe(SddOrchestrator.PubSub, WorkerChannel.topic(project.id))

      home = tmp_home()
      config = build_config(base, credential, project.id, worker.id)

      {:ok, pid} =
        GatewayConnection.start_link(config, home: home, observe_interval: @observe_interval)

      on_exit(fn -> stop_gateway(pid) end)

      wait_until(fn -> Transport.attached(project.id) != [] end)
      assert Transport.deliver(command) == :ok

      assert_receive {:worker_event, %{"event_type" => "workspace_ready"}}, 3_000
      assert_receive {:worker_event, %{"event_type" => "progress", "sequence" => 2}}, 3_000
      assert_receive {:worker_event, %{"event_type" => "progress", "sequence" => 3}}, 3_000

      wait_until(fn ->
        match?({:ok, %{current: %{last_sequence: 3}}}, RunState.load(home))
      end)

      {reconcile_command, reconcile_envelope} = enqueue_reconcile(project, feature, run)
      EnvelopeSource.script(reconcile_command.id, reconcile_envelope)

      assert Transport.deliver(reconcile_command) == :ok

      assert_receive {:worker_reconciliation, %{"attempts" => [_ | _]} = snapshot}, 3_000

      assert {:ok, %{current: current}} = RunState.load(home)

      assert snapshot["attempts"] == [
               %{
                 "run_id" => current.run_id,
                 "attempt_number" => current.attempt_number,
                 "command_id" => current.command_id,
                 "fence_token" => current.fence_token,
                 "last_sequence" => current.last_sequence,
                 "branch" => current.branch,
                 "state" => "running"
               }
             ]

      assert snapshot["worker_id"] == worker.id
      assert snapshot["type"] == "reconciliation_snapshot"
    end

    test "a reconnect against the same durable home pushes an authoritative snapshot on join, agreeing with the last accepted sequence",
         %{control_plane_address: base} do
      %{project: project, feature: feature, run: run, credential: credential, worker: worker} =
        paired_and_bound_project()

      configure(stable_two_step_script())

      {command, envelope, _attempt} = enqueue_start_with_real_repository(project, feature, run)
      EnvelopeSource.script(command.id, envelope)

      :ok = PubSub.subscribe(SddOrchestrator.PubSub, WorkerChannel.topic(project.id))

      home = tmp_home()
      config = build_config(base, credential, project.id, worker.id)

      {:ok, first_pid} =
        GatewayConnection.start_link(config, home: home, observe_interval: @observe_interval)

      wait_until(fn -> Transport.attached(project.id) != [] end)
      assert Transport.deliver(command) == :ok

      assert_receive {:worker_event, %{"event_type" => "workspace_ready"}}, 3_000
      assert_receive {:worker_event, %{"event_type" => "progress", "sequence" => 2}}, 3_000
      assert_receive {:worker_event, %{"event_type" => "progress", "sequence" => 3}}, 3_000

      last_accepted_sequence = 3

      wait_until(fn ->
        match?(
          {:ok, %{current: %{last_sequence: ^last_accepted_sequence}}},
          RunState.load(home)
        )
      end)

      stop_gateway(first_pid)
      wait_until(fn -> Transport.attached(project.id) == [] end)

      {:ok, second_pid} =
        GatewayConnection.start_link(config, home: home, observe_interval: @observe_interval)

      on_exit(fn -> stop_gateway(second_pid) end)

      wait_until(fn -> Transport.attached(project.id) != [] end)

      assert_receive {:worker_reconciliation,
                      %{"attempts" => [%{"last_sequence" => ^last_accepted_sequence}]} = snapshot},
                     3_000

      assert {:ok, %{current: current}} = RunState.load(home)

      assert snapshot["attempts"] == [
               %{
                 "run_id" => current.run_id,
                 "attempt_number" => current.attempt_number,
                 "command_id" => current.command_id,
                 "fence_token" => current.fence_token,
                 "last_sequence" => current.last_sequence,
                 "branch" => current.branch,
                 "state" => "running"
               }
             ]
    end
  end

  describe "CommandHandler: direct unit checks for cancel, reconcile, resume, and retry" do
    setup do
      home = tmp_home()

      current = %RunState{
        command_id: "cmd_current",
        operation: "start",
        project_id: DeliveryProtocolFixtures.project_id(),
        feature_id: DeliveryProtocolFixtures.feature_id(),
        run_id: DeliveryProtocolFixtures.run_id(),
        attempt_number: 1,
        fence_token: 2,
        manifest_digest: String.duplicate("a", 64),
        last_sequence: 3,
        agent_thread_ref: "thr_prior",
        branch: "sdd/feature/ftr-0002/run-0003",
        lifecycle: "accepted"
      }

      :ok = RunState.store(%{current: current, previous: nil}, home)

      %{home: home, current: current}
    end

    test "a cancel carrying a stale fence token is refused", %{home: home, current: current} do
      envelope =
        DeliveryProtocolFixtures.cancel_command(%{
          "run_id" => current.run_id,
          "fence_token" => current.fence_token - 1
        })

      ack = CommandHandler.handle_command(envelope, 1, home)

      assert ack["status"] == "rejected"
      assert ack["reason"] == "not_current_attempt"
      assert {:ok, %{current: ^current}} = RunState.load(home)
    end

    test "a cancel naming an already-terminal attempt is refused", %{
      home: home,
      current: current
    } do
      terminal_current = %{current | lifecycle: "failed"}
      :ok = RunState.store(%{current: terminal_current, previous: nil}, home)

      envelope =
        DeliveryProtocolFixtures.cancel_command(%{
          "run_id" => current.run_id,
          "fence_token" => current.fence_token
        })

      ack = CommandHandler.handle_command(envelope, 1, home)

      assert ack["status"] == "rejected"
      assert ack["reason"] == "attempt_already_terminal"
      assert {:ok, %{current: ^terminal_current}} = RunState.load(home)
    end

    test "a cancel naming the current, non-terminal attempt is accepted without mutating RunState",
         %{home: home, current: current} do
      envelope =
        DeliveryProtocolFixtures.cancel_command(%{
          "run_id" => current.run_id,
          "fence_token" => current.fence_token
        })

      ack = CommandHandler.handle_command(envelope, 1, home)

      assert ack["status"] == "accepted"
      assert ack["reason"] == nil
      assert {:ok, %{current: ^current, previous: nil}} = RunState.load(home)
    end

    test "reconcile is always accepted regardless of RunState content", %{
      home: home,
      current: current
    } do
      envelope = DeliveryProtocolFixtures.command(%{"operation" => "reconcile", "payload" => %{}})

      ack = CommandHandler.handle_command(envelope, 1, home)

      assert ack["status"] == "accepted"
      assert ack["reason"] == nil
      assert {:ok, %{current: ^current}} = RunState.load(home)
    end

    test "reconcile is accepted even when there is no current attempt at all" do
      fresh_home = tmp_home()
      envelope = DeliveryProtocolFixtures.command(%{"operation" => "reconcile", "payload" => %{}})

      ack = CommandHandler.handle_command(envelope, 1, fresh_home)

      assert ack["status"] == "accepted"
      assert RunState.load(fresh_home) == {:ok, RunState.empty()}
    end

    test "resume carries the current attempt's agent_thread_ref forward when accepted", %{
      home: home,
      current: current
    } do
      manifest =
        DeliveryProtocolFixtures.manifest(%{
          "run_id" => current.run_id,
          "attempt_number" => current.attempt_number + 1,
          "continuation" => %{
            "reason" => "blocking_answer",
            "prior_attempt_number" => current.attempt_number
          }
        })

      envelope =
        DeliveryProtocolFixtures.command(%{
          "run_id" => current.run_id,
          "operation" => "resume",
          "attempt_number" => current.attempt_number + 1,
          "fence_token" => current.fence_token + 1,
          "manifest_digest" => ExecutionManifest.digest(manifest),
          "payload" => %{"manifest" => ExecutionManifest.to_map(manifest)}
        })

      ack = CommandHandler.handle_command(envelope, 1, home)

      assert ack["status"] == "accepted"

      assert {:ok, %{current: new_current, previous: previous}} = RunState.load(home)
      assert new_current.agent_thread_ref == current.agent_thread_ref
      assert new_current.branch == manifest.target_branch
      assert new_current.attempt_number == current.attempt_number + 1
      assert previous.lifecycle == "stopped"
    end

    test "retry carries the current attempt's agent_thread_ref forward when accepted", %{
      home: home,
      current: current
    } do
      manifest =
        DeliveryProtocolFixtures.manifest(%{
          "run_id" => current.run_id,
          "attempt_number" => current.attempt_number + 1,
          "continuation" => %{
            "reason" => "manual_retry",
            "prior_attempt_number" => current.attempt_number
          }
        })

      envelope =
        DeliveryProtocolFixtures.command(%{
          "run_id" => current.run_id,
          "operation" => "retry",
          "attempt_number" => current.attempt_number + 1,
          "fence_token" => current.fence_token + 1,
          "manifest_digest" => ExecutionManifest.digest(manifest),
          "payload" => %{"manifest" => ExecutionManifest.to_map(manifest)}
        })

      ack = CommandHandler.handle_command(envelope, 1, home)

      assert ack["status"] == "accepted"

      assert {:ok, %{current: new_current}} = RunState.load(home)
      assert new_current.agent_thread_ref == current.agent_thread_ref
    end

    test "a genuine start never carries a prior agent_thread_ref forward, even for the same run",
         %{home: home, current: current} do
      manifest =
        DeliveryProtocolFixtures.manifest(%{
          "run_id" => current.run_id,
          "attempt_number" => current.attempt_number + 1,
          "continuation" => %{
            "reason" => "automatic_retry",
            "prior_attempt_number" => current.attempt_number
          }
        })

      envelope =
        DeliveryProtocolFixtures.command(%{
          "run_id" => current.run_id,
          "operation" => "start",
          "attempt_number" => current.attempt_number + 1,
          "fence_token" => current.fence_token + 1,
          "manifest_digest" => ExecutionManifest.digest(manifest),
          "payload" => %{"manifest" => ExecutionManifest.to_map(manifest)}
        })

      ack = CommandHandler.handle_command(envelope, 1, home)

      assert ack["status"] == "accepted"

      assert {:ok, %{current: new_current}} = RunState.load(home)
      assert new_current.agent_thread_ref == nil
    end
  end

  # --- scripted agent helpers -----------------------------------------------

  defp configure(path), do: Application.put_env(:sdd_orchestrator, :agent_executable, path)

  # Emits one progress line, then blocks well past every assertion window in
  # the cancel test below, so a real, still-alive subprocess exists for the
  # cancel to actually stop rather than merely observing a process that was
  # already finishing on its own.
  defp sleepy_script do
    write_script!("""
    #!/bin/sh
    if [ "$1" = "--version" ]; then
      echo "9.9.9 (Claude Code)"
      exit 0
    fi
    echo '{"type":"system","subtype":"init","session_id":"thr_cancel_target"}'
    echo '{"type":"assistant","message":{"content":[{"type":"text","text":"still working"}]}}'
    sleep 5
    echo '{"type":"assistant","message":{"content":[{"type":"text","text":"should never be observed"}]}}'
    echo '{"type":"result","is_error":false,"result":"done"}'
    exit 0
    """)
  end

  # Two progress lines, then a long block before any result — keeps
  # `RunState.current.last_sequence` stable at exactly 3 (workspace_ready,
  # then these two) for the whole reconcile round trip, rather than racing
  # ahead into required-check and verification-completed sequences the
  # reconcile tests below do not want to have to account for.
  defp stable_two_step_script do
    write_script!("""
    #!/bin/sh
    if [ "$1" = "--version" ]; then
      echo "9.9.9 (Claude Code)"
      exit 0
    fi
    echo '{"type":"system","subtype":"init","session_id":"thr_reconcile"}'
    echo '{"type":"assistant","message":{"content":[{"type":"text","text":"step one"}]}}'
    echo '{"type":"assistant","message":{"content":[{"type":"text","text":"step two"}]}}'
    sleep 5
    echo '{"type":"result","is_error":false,"result":"done"}'
    exit 0
    """)
  end

  # Reports whatever `--resume <value>` argument it was actually launched
  # with (or "none" when absent) as its own progress line — real, direct
  # proof that a resume/retry command's carried-forward `agent_thread_ref`
  # reached the real subprocess argv, not just a soft `resumed?` flag.
  # Every invocation reports the same fixed session_id, so the persisted
  # `agent_thread_ref` is identical and comparable across every attempt.
  defp resume_probe_script do
    write_script!("""
    #!/bin/sh
    if [ "$1" = "--version" ]; then
      echo "9.9.9 (Claude Code)"
      exit 0
    fi
    resumed="none"
    prev=""
    for arg in "$@"; do
      if [ "$prev" = "--resume" ]; then
        resumed="$arg"
      fi
      prev="$arg"
    done
    echo "{\\"type\\":\\"system\\",\\"subtype\\":\\"init\\",\\"session_id\\":\\"thr_lifecycle_probe\\"}"
    echo "{\\"type\\":\\"assistant\\",\\"message\\":{\\"content\\":[{\\"type\\":\\"text\\",\\"text\\":\\"resumed=$resumed\\"}]}}"
    echo "{\\"type\\":\\"result\\",\\"is_error\\":false,\\"result\\":\\"done\\"}"
    exit 0
    """)
  end

  defp write_script!(content) do
    path =
      Path.join(
        System.tmp_dir!(),
        "sdd-command-lifecycle-script-#{System.unique_integer([:positive])}.sh"
      )

    File.write!(path, content)
    File.chmod!(path, 0o700)
    path
  end

  # The launched agent's real Session pid, peeked from the live
  # `GatewayConnection`'s own socket assigns the same way
  # `AgentEventDeliveryTest.force_transport_drop/1` already peeks at socket
  # state for a different reason — `:sys.get_state/1` only returns once the
  # process is between callbacks, so this can never race an in-flight
  # `handle_message/4` that has not yet assigned `:launch`.
  defp launch_session_pid(gateway_pid) do
    socket = :sys.get_state(gateway_pid)
    socket.assigns.launch.handle.reference
  end

  # --- helpers ---------------------------------------------------------------

  defp restore_env(key, {:ok, value}), do: Application.put_env(:sdd_orchestrator, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:sdd_orchestrator, key)

  defp acknowledged?(command_id) do
    match?({:ok, %{state: "acknowledged"}}, CommandOutbox.fetch(command_id))
  end

  defp tmp_home do
    dir =
      Path.join(
        System.tmp_dir!(),
        "worker-command-lifecycle-test-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp build_config(control_plane_address, worker_credential, project_id, worker_id) do
    %Configuration{
      control_plane_address: control_plane_address,
      device_workspace_id: Ecto.UUID.generate(),
      worker_credential: worker_credential,
      agent_adapter: "claude_code",
      agent_executable: "/usr/local/bin/claude",
      workspace_root: System.tmp_dir!(),
      project_id: project_id,
      worker_id: worker_id
    }
  end

  defp stop_gateway(pid) do
    if is_pid(pid) and Process.alive?(pid) do
      Process.unlink(pid)
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      after
        1_000 -> :ok
      end
    end
  end

  # The control plane stores every event the worker reports, and each stored one
  # moves the attempt's own version. A supersession therefore reads the version
  # the attempt holds now instead of the one it held before the run said
  # anything.
  defp supersede!(attempt) do
    current = Repo.get!(RunAttempt, attempt.id)

    Repo.update!(RunAttempt.transition_changeset(current, "superseded", current.state_version))
  end

  defp wait_until(fun, timeout \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition not met within timeout")

      true ->
        Process.sleep(10)
        do_wait_until(fun, deadline)
    end
  end

  defp git!(directory, args) do
    identity = [
      "-c",
      "user.name=SDD Orchestrator Test",
      "-c",
      "user.email=test@example.invalid",
      "-c",
      "commit.gpgsign=false",
      "-c",
      "init.defaultBranch=base"
    ]

    {output, 0} = System.cmd("git", identity ++ args, cd: directory, stderr_to_stdout: true)
    String.trim(output)
  end

  # Creates and proves a real local git fixture repository for this run's
  # workspace and returns its resolvable base revision, reused unchanged
  # across every attempt of the run (start, resume, retry all share the same
  # workspace and branch — the workspace path carries no attempt_number).
  defp init_repository(project, feature, run, required_checks) do
    probe =
      DeliveryProtocolFixtures.manifest(%{
        "project_id" => project.id,
        "feature_id" => feature.id,
        "run_id" => run.id,
        "attempt_number" => 1,
        "required_checks" => required_checks
      })

    {:ok, _workspace} = Workspace.prepare(probe)
    {:ok, directory} = Workspace.working_directory(probe)

    git!(directory, ["init", "--quiet"])
    git!(directory, ["commit", "--allow-empty", "--quiet", "--message", "base"])
    git!(directory, ["rev-parse", "HEAD"])
  end

  # Builds and enqueues one real, manifest-bound command for `operation` at
  # `attempt_number`/`fence_token`, bound to the already-proven repository at
  # `revision`.
  defp enqueue_attempt(project, feature, run, revision, opts) do
    operation = Keyword.fetch!(opts, :operation)
    attempt_number = Keyword.fetch!(opts, :attempt_number)
    fence_token = Keyword.fetch!(opts, :fence_token)
    continuation = Keyword.fetch!(opts, :continuation)

    required_checks =
      Keyword.get(opts, :required_checks, [%{"name" => "noop", "command" => "true"}])

    manifest =
      DeliveryProtocolFixtures.manifest(%{
        "project_id" => project.id,
        "feature_id" => feature.id,
        "run_id" => run.id,
        "attempt_number" => attempt_number,
        "repository_base_revision" => revision,
        "continuation" => continuation,
        "required_checks" => required_checks
      })

    digest = ExecutionManifest.digest(manifest)

    attempt =
      DeliveryFixtures.attempt_fixture(run, %{
        attempt_number: attempt_number,
        fence_token: fence_token,
        manifest_digest: digest,
        continuation_reason: continuation["reason"]
      })

    {:ok, command} =
      CommandOutbox.enqueue(%{
        id: Ecto.UUID.generate(),
        project_id: project.id,
        run_id: run.id,
        attempt_id: attempt.id,
        operation: operation,
        expected_state_version: run.state_version,
        manifest_digest: digest
      })

    envelope =
      DeliveryProtocolFixtures.command(%{
        "command_id" => command.id,
        "project_id" => project.id,
        "feature_id" => feature.id,
        "run_id" => run.id,
        "attempt_number" => attempt_number,
        "fence_token" => fence_token,
        "operation" => operation,
        "expected_state_version" => command.expected_state_version,
        "manifest_digest" => digest,
        "payload" => %{"manifest" => ExecutionManifest.to_map(manifest)}
      })

    {command, envelope, attempt}
  end

  defp enqueue_start_with_real_repository(project, feature, run) do
    required_checks = [%{"name" => "noop", "command" => "true"}]
    revision = init_repository(project, feature, run, required_checks)

    enqueue_attempt(project, feature, run, revision,
      operation: "start",
      attempt_number: 1,
      fence_token: 1,
      continuation: %{"reason" => "initial", "prior_attempt_number" => nil},
      required_checks: required_checks
    )
  end

  defp enqueue_cancel(project, feature, run) do
    {:ok, command} =
      CommandOutbox.enqueue(%{
        id: Ecto.UUID.generate(),
        project_id: project.id,
        run_id: run.id,
        operation: "cancel",
        expected_state_version: run.state_version
      })

    envelope =
      DeliveryProtocolFixtures.cancel_command(%{
        "command_id" => command.id,
        "project_id" => project.id,
        "feature_id" => feature.id,
        "run_id" => run.id,
        "expected_state_version" => command.expected_state_version
      })

    {command, envelope}
  end

  defp enqueue_reconcile(project, feature, run) do
    {:ok, command} =
      CommandOutbox.enqueue(%{
        id: Ecto.UUID.generate(),
        project_id: project.id,
        run_id: run.id,
        operation: "reconcile",
        expected_state_version: run.state_version
      })

    envelope =
      DeliveryProtocolFixtures.command(%{
        "command_id" => command.id,
        "project_id" => project.id,
        "feature_id" => feature.id,
        "run_id" => run.id,
        "operation" => "reconcile",
        "expected_state_version" => command.expected_state_version,
        "payload" => %{}
      })

    {command, envelope}
  end

  defp paired_and_bound_project do
    account = account_fixture()
    personal_workspace = workspace_fixture(account)
    device_workspace = %DeviceWorkspace{id: Ecto.UUID.generate()}
    project = local_project_fixture(personal_workspace, portable_identifier())
    feature = DeliveryFixtures.feature_fixture(project, account)
    run = DeliveryFixtures.run_fixture(project, feature)

    {worker, credential} = available_worker_fixture(device_workspace)

    {:ok, %{binding: binding}} =
      HostedLocalRepositoryBindings.put_validated_binding(
        personal_workspace,
        project.id,
        device_workspace,
        worker.id,
        project.canonical_repository_id
      )

    %{
      project: project,
      feature: feature,
      run: run,
      worker: worker,
      credential: credential,
      device_workspace: device_workspace,
      binding: binding
    }
  end

  defp local_project_fixture(personal_workspace, repository_id) do
    %Project{}
    |> Project.changeset(%{
      name: "local-project-#{System.unique_integer([:positive])}",
      workspace_id: personal_workspace.id,
      storage_mode: "hosted",
      repository_provider: "local",
      canonical_repository_id: repository_id
    })
    |> Repo.insert!()
  end

  defp available_worker_fixture(device_workspace) do
    {worker, credential} = paired_worker_fixture(device_workspace)
    {:ok, worker} = Pairing.mark_seen(worker)
    {worker, credential}
  end

  defp paired_worker_fixture(device_workspace) do
    {:ok, %{code: code}} = Pairing.start_pairing(device_workspace.id)

    {:ok, %{worker: worker, credential: credential}} =
      Pairing.complete_pairing(code, %{
        os_family: "macos",
        os_major: "26",
        app_version: "1.0.0",
        protocol_version: "1"
      })

    {worker, credential}
  end

  defp portable_identifier do
    salt = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    digest = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    "local-repo:v1:#{salt}:#{digest}"
  end
end
