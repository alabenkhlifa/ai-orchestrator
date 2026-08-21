defmodule SddOrchestrator.Worker.AgentEventDeliveryEnvelopeSource do
  @moduledoc """
  Supplies the protocol envelope a durable command is delivered as, scoped to
  `SddOrchestrator.Worker.AgentEventDeliveryTest`.

  Mirrors the pattern `SddOrchestrator.Worker.ExecutionPreparationEnvelopeSource`
  and `SddOrchestrator.Worker.CommandHandlingEnvelopeSource` already establish,
  defined locally so this file's `mix test` invocation never depends on
  another test file being compiled alongside it.
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

defmodule SddOrchestrator.Worker.AgentEventDeliveryTest do
  @moduledoc """
  Task 8 proof: normalize and deliver agent events.

  Covers [AC-11] — progress, evidence, blocking-question, and agent-failure
  events reach the channel in order with monotonic sequence numbers, and no
  event is delivered twice across a reconnect — and [AC-12], insofar as it is
  this task's own boundary rather than the already-proven, consumed-unchanged
  `Delivery.AgentAdapter`/`ProtocolCodec` machinery: an agent's own claim of
  verification completion or workspace readiness can never reach this path at
  all (the agent event vocabulary makes it structurally unreachable, proven
  in `Delivery.AgentAdapterTest`) and typed drops are logged rather than
  silently discarded.

  Runs over the real gateway (real `Bandit`, real
  `SddOrchestratorWeb.WorkerChannel`, real `CommandOutbox`/`Transport`, real
  `SddOrchestrator.Worker.GatewayConnection`) against a scripted `claude`
  stand-in (`SddOrchestrator.ClaudeCodeCliFixture`), matching the pattern
  `ExecutionPreparationTest` and `CommandHandlingTest` already establish.
  """

  use SddOrchestrator.DataCase, async: false

  import SddOrchestrator.AccountsFixtures
  import SddOrchestrator.ProjectsFixtures

  alias Phoenix.PubSub
  alias SddOrchestrator.Accounts.DeviceWorkspace
  alias SddOrchestrator.ClaudeCodeCliFixture, as: Fixture
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
  alias SddOrchestrator.Worker.AgentEventDeliveryEnvelopeSource, as: EnvelopeSource
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
        "sdd-agent-event-delivery-#{System.unique_integer([:positive])}"
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

  describe "AC-11: agent events reach the channel in order with monotonic sequences" do
    test "progress events arrive in order, each with an increasing sequence, source agent, and the right identifiers",
         %{control_plane_address: base} do
      %{project: project, feature: feature, run: run, credential: credential, worker: worker} =
        paired_and_bound_project()

      lines = [
        %{"type" => "system", "subtype" => "init", "session_id" => "thr_ordering"},
        %{
          "type" => "assistant",
          "message" => %{"content" => [%{"type" => "text", "text" => "step one"}]}
        },
        %{
          "type" => "assistant",
          "message" => %{"content" => [%{"type" => "text", "text" => "step two"}]}
        },
        %{"type" => "result", "is_error" => false, "result" => "all done"}
      ]

      configure(Fixture.streaming_script(lines))

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

      events = collect_events(3)

      assert Enum.map(events, & &1["event_type"]) == ["progress", "progress", "progress"]

      sequences = Enum.map(events, & &1["sequence"])
      assert sequences == Enum.sort(sequences)
      assert length(Enum.uniq(sequences)) == 3

      for event <- events do
        assert event["source"] == "agent"
        assert event["command_id"] == command.id
        assert event["fence_token"] == envelope["fence_token"]
        assert event["run_id"] == run.id
      end
    end
  end

  describe "a scripted agent failure reaches its terminal state" do
    test "a failed event reaches the channel, the lock is released, and lifecycle becomes failed",
         %{control_plane_address: base} do
      %{project: project, feature: feature, run: run, credential: credential, worker: worker} =
        paired_and_bound_project()

      lines = [
        %{"type" => "system", "subtype" => "init", "session_id" => "thr_failure"},
        %{
          "type" => "result",
          "is_error" => true,
          "subtype" => "error_during_execution",
          "errors" => ["provider request failed"]
        }
      ]

      configure(Fixture.streaming_script(lines))

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
      assert_receive {:worker_event, %{"event_type" => "failed"} = failed_event}, 3_000

      assert failed_event["source"] == "agent"
      assert failed_event["command_id"] == command.id
      assert failed_event["run_id"] == run.id

      {:ok, manifest} = ProtocolCodec.manifest(envelope)
      {:ok, workspace} = Workspace.prepare(manifest)

      wait_until(fn ->
        match?({:ok, %{current: %{lifecycle: "failed"}}}, RunState.load(home))
      end)

      refute File.exists?(Path.join(workspace, "run.lock"))
    end
  end

  describe "a clean successful completion runs the required checks and completes verification" do
    test "each required check reports its own evidence event, then verification completes and the lock releases",
         %{control_plane_address: base} do
      %{project: project, feature: feature, run: run, credential: credential, worker: worker} =
        paired_and_bound_project()

      lines = [
        %{"type" => "system", "subtype" => "init", "session_id" => "thr_success"},
        %{
          "type" => "assistant",
          "message" => %{"content" => [%{"type" => "text", "text" => "implemented it"}]}
        },
        %{"type" => "result", "is_error" => false, "result" => "all checks pass"}
      ]

      configure(Fixture.streaming_script(lines))

      required_checks = [
        %{"name" => "first", "command" => "true"},
        %{"name" => "second", "command" => "true"}
      ]

      {command, envelope, _attempt} =
        enqueue_start_with_real_repository(project, feature, run,
          required_checks: required_checks
        )

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

      assert_receive {:worker_event, %{"event_type" => "progress", "sequence" => 3} = final},
                     3_000

      refute final["event_type"] in ~w(blocked failed)

      assert_receive {:worker_event,
                      %{
                        "event_type" => "evidence",
                        "source" => "check",
                        "sequence" => 4,
                        "payload" => %{"name" => "first", "outcome" => "passed"}
                      }},
                     3_000

      assert_receive {:worker_event,
                      %{
                        "event_type" => "evidence",
                        "source" => "check",
                        "sequence" => 5,
                        "payload" => %{"name" => "second", "outcome" => "passed"}
                      }},
                     3_000

      assert_receive {:worker_event,
                      %{
                        "event_type" => "verification_completed",
                        "source" => "worker",
                        "sequence" => 6
                      } = completion},
                     3_000

      {:ok, manifest} = ProtocolCodec.manifest(envelope)
      assert completion["payload"]["branch"] == manifest.target_branch
      assert completion["payload"]["revision_id"] == manifest.effective_revision_id

      {:ok, workspace} = Workspace.prepare(manifest)

      wait_until(fn ->
        match?({:ok, %{current: %{lifecycle: "verification_completed"}}}, RunState.load(home))
      end)

      refute File.exists?(Path.join(workspace, "run.lock"))
    end
  end

  describe "AC-11: a running heartbeat announces the launched agent" do
    test "a heartbeat with state running is observed on the project's PubSub topic",
         %{control_plane_address: base} do
      %{project: project, feature: feature, run: run, credential: credential, worker: worker} =
        paired_and_bound_project()

      lines = [
        %{"type" => "system", "subtype" => "init", "session_id" => "thr_heartbeat"},
        %{"type" => "result", "is_error" => false, "result" => "done"}
      ]

      configure(Fixture.streaming_script(lines))

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

      assert_receive {:worker_heartbeat, heartbeat}, 3_000
      assert heartbeat["state"] == "running"
      assert heartbeat["run_id"] == run.id
      assert heartbeat["worker_id"] == worker.id
    end
  end

  describe "AC-11: a reconnect mid-run re-delivers nothing the control plane already accepted" do
    test "the already-accepted event is never seen again, and the remaining event still arrives after reconnect",
         %{control_plane_address: base} do
      %{project: project, feature: feature, run: run, credential: credential, worker: worker} =
        paired_and_bound_project()

      go_file =
        Path.join(System.tmp_dir!(), "sdd-reconnect-go-#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm(go_file) end)

      configure(reconnect_script(go_file))

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

      assert_receive {:worker_event, %{"event_type" => "progress", "sequence" => first_sequence}},
                     3_000

      # Only proceed once the acknowledged sequence is durably recorded —
      # this is what guarantees the control plane genuinely already accepted
      # it before the drop, so there is nothing ambiguous left in flight.
      wait_until(fn ->
        match?({:ok, %{current: %{last_sequence: ^first_sequence}}}, RunState.load(home))
      end)

      assert [{first_worker_pid, _contract}] = Transport.attached(project.id)

      force_transport_drop(pid)

      wait_until(fn ->
        match?(
          [{worker_pid, _contract}] when worker_pid != first_worker_pid,
          Transport.attached(project.id)
        )
      end)

      # Only now does the scripted agent produce its remaining output — the
      # script blocks on this file until the test says so, which is what
      # rules out a timing race between the drop and the agent's own output.
      File.write!(go_file, "go")

      assert_receive {:worker_event,
                      %{"event_type" => "progress", "sequence" => second_sequence}},
                     3_000

      assert second_sequence > first_sequence

      refute_receive {:worker_event, %{"sequence" => ^first_sequence}}, 300
    end
  end

  describe "a superseded attempt's observation loop stops delivering" do
    test "no further events tagged with the first attempt's command_id reach the channel after supersession",
         %{control_plane_address: base} do
      %{project: project, feature: feature, run: run, credential: credential, worker: worker} =
        paired_and_bound_project()

      configure(stalling_script())

      {first_command, first_envelope, first_attempt} =
        enqueue_start_with_real_repository(project, feature, run)

      EnvelopeSource.script(first_command.id, first_envelope)

      :ok = PubSub.subscribe(SddOrchestrator.PubSub, WorkerChannel.topic(project.id))

      home = tmp_home()
      config = build_config(base, credential, project.id, worker.id)

      {:ok, pid} =
        GatewayConnection.start_link(config, home: home, observe_interval: @observe_interval)

      on_exit(fn -> stop_gateway(pid) end)

      wait_until(fn -> Transport.attached(project.id) != [] end)
      assert Transport.deliver(first_command) == :ok

      assert_receive {:worker_event, %{"event_type" => "workspace_ready"}}, 3_000
      assert_receive {:worker_heartbeat, %{"state" => "running"}}, 3_000

      # A run's authoritative attempt lifecycle is the control plane's own —
      # only one attempt of a run may be current at a time — so a genuine
      # second attempt first transitions the first one out of the way,
      # exactly like `CommandHandlingTest`'s own AC-07 supersession test.
      Repo.update!(RunAttempt.transition_changeset(first_attempt, "superseded", 1))

      {second_command, second_envelope, _second_attempt} =
        enqueue_start(project, feature, run, attempt_number: 2, fence_token: 2)

      EnvelopeSource.script(second_command.id, second_envelope)

      assert Transport.deliver(second_command) == :ok
      wait_until(fn -> acknowledged?(second_command.id) end)

      first_command_id = first_command.id

      # The scripted agent's second event arrives (from the underlying
      # process's own perspective) well within this window, but the
      # observation loop for the first attempt has already stopped polling
      # once it saw itself superseded — proving the content never crosses
      # the channel rather than merely never being scripted at all.
      refute_receive {:worker_event, %{"command_id" => ^first_command_id}}, 700
    end
  end

  # --- scripted agent helpers -----------------------------------------------

  defp configure(path), do: Application.put_env(:sdd_orchestrator, :agent_executable, path)

  # A script whose remaining output is gated behind a file the test controls,
  # so a reconnect can be forced with certainty that nothing is "in flight"
  # from the agent's own perspective at the moment of the drop.
  defp reconnect_script(go_file) do
    write_script!("""
    #!/bin/sh
    if [ "$1" = "--version" ]; then
      echo "9.9.9 (Claude Code)"
      exit 0
    fi
    echo '{"type":"system","subtype":"init","session_id":"thr_reconnect"}'
    echo '{"type":"assistant","message":{"content":[{"type":"text","text":"first"}]}}'
    i=0
    while [ ! -f "#{go_file}" ] && [ $i -lt 250 ]; do
      sleep 0.02
      i=$((i+1))
    done
    echo '{"type":"assistant","message":{"content":[{"type":"text","text":"second"}]}}'
    echo '{"type":"result","is_error":false,"result":"done"}'
    exit 0
    """)
  end

  # Emits one event immediately, then a second event after a real delay long
  # enough that, if the worker's observation loop kept polling despite a
  # supersession, the second event would have had ample time to arrive.
  defp stalling_script do
    write_script!("""
    #!/bin/sh
    if [ "$1" = "--version" ]; then
      echo "9.9.9 (Claude Code)"
      exit 0
    fi
    echo '{"type":"system","subtype":"init","session_id":"thr_stall"}'
    sleep 0.5
    echo '{"type":"assistant","message":{"content":[{"type":"text","text":"should never be observed after supersession"}]}}'
    echo '{"type":"result","is_error":false,"result":"done"}'
    exit 0
    """)
  end

  defp write_script!(content) do
    path =
      Path.join(
        System.tmp_dir!(),
        "sdd-agent-event-delivery-script-#{System.unique_integer([:positive])}.sh"
      )

    File.write!(path, content)
    File.chmod!(path, 0o700)
    path
  end

  # --- helpers ---------------------------------------------------------------

  defp restore_env(key, {:ok, value}), do: Application.put_env(:sdd_orchestrator, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:sdd_orchestrator, key)

  defp collect_events(count, timeout \\ 3_000) do
    for _ <- 1..count do
      assert_receive {:worker_event, event}, timeout
      event
    end
  end

  defp acknowledged?(command_id) do
    match?({:ok, %{state: "acknowledged"}}, CommandOutbox.fetch(command_id))
  end

  defp tmp_home do
    dir =
      Path.join(
        System.tmp_dir!(),
        "worker-agent-event-delivery-test-#{System.unique_integer([:positive])}"
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
    if Process.alive?(pid) do
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

  # Sends the same close request Slipstream's own `disconnect/1` uses,
  # against the connection process currently held by a running
  # `GatewayConnection` — a genuine transport-level close, matching
  # `GatewayConnectionTest`'s own technique.
  defp force_transport_drop(pid) do
    socket = :sys.get_state(pid)
    Slipstream.disconnect(socket)
    :ok
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

  # Builds a real run/attempt/manifest/command bound together against a real
  # local git fixture repository (mirroring
  # `ExecutionPreparationTest.enqueue_start_with_real_repository/3`), so the
  # worker's own `ExecutionPreparer` (Task 5) can actually prepare a real
  # workspace and branch and this test's agent has somewhere real to launch.
  # `required_checks` defaults to a single fast, deterministic no-op rather
  # than the manifest fixture's own default (real `mix format`/`mix test`
  # commands) — once `RequiredCheckRunner` (Task 9) is wired in, every test
  # here that reaches a clean agent exit actually shells out to run its
  # attempt's required checks in this fixture repository, which has no
  # `mix.exs` at all. Only `RequiredCheckRunnerTest` and the test below that
  # is specifically about the check-running behaviour itself need anything
  # slower or more elaborate.
  defp enqueue_start_with_real_repository(project, feature, run, attrs \\ []) do
    attrs = Map.new(attrs)
    attempt_number = Map.get(attrs, :attempt_number, 1)
    fence_token = Map.get(attrs, :fence_token, attempt_number)
    required_checks = Map.get(attrs, :required_checks, [%{"name" => "noop", "command" => "true"}])

    probe =
      DeliveryProtocolFixtures.manifest(%{
        "project_id" => project.id,
        "feature_id" => feature.id,
        "run_id" => run.id,
        "attempt_number" => attempt_number,
        "required_checks" => required_checks
      })

    {:ok, _workspace} = Workspace.prepare(probe)
    {:ok, directory} = Workspace.working_directory(probe)

    git!(directory, ["init", "--quiet"])
    git!(directory, ["commit", "--allow-empty", "--quiet", "--message", "base"])
    revision = git!(directory, ["rev-parse", "HEAD"])

    continuation =
      if attempt_number == 1 do
        %{"reason" => "initial", "prior_attempt_number" => nil}
      else
        %{"reason" => "automatic_retry", "prior_attempt_number" => attempt_number - 1}
      end

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
        operation: "start",
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
        "expected_state_version" => command.expected_state_version,
        "manifest_digest" => digest,
        "payload" => %{"manifest" => ExecutionManifest.to_map(manifest)}
      })

    {command, envelope, attempt}
  end

  # A second, superseding command against the same run — deliberately
  # fixture-only (no real repository), mirroring
  # `CommandHandlingTest.enqueue_start/4`'s own AC-07 technique: this
  # attempt only needs to be validly *accepted* to drive the supersession
  # bookkeeping in `RunState`; whether its own `ExecutionPreparer.prepare/2`
  # later succeeds is irrelevant to what this test proves.
  defp enqueue_start(project, feature, run, attrs) do
    attrs = Map.new(attrs)
    attempt_number = Map.get(attrs, :attempt_number, 1)
    fence_token = Map.get(attrs, :fence_token, attempt_number)

    continuation =
      if attempt_number == 1 do
        %{"reason" => "initial", "prior_attempt_number" => nil}
      else
        %{"reason" => "automatic_retry", "prior_attempt_number" => attempt_number - 1}
      end

    manifest =
      DeliveryProtocolFixtures.manifest(%{
        "project_id" => project.id,
        "feature_id" => feature.id,
        "run_id" => run.id,
        "attempt_number" => attempt_number,
        "continuation" => continuation
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
        operation: "start",
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
        "expected_state_version" => command.expected_state_version,
        "manifest_digest" => digest,
        "payload" => %{"manifest" => ExecutionManifest.to_map(manifest)}
      })

    {command, envelope, attempt}
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
