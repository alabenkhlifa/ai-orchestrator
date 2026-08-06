defmodule SddOrchestrator.Worker.CommandHandlingEnvelopeSource do
  @moduledoc """
  Supplies the protocol envelope a durable command is delivered as, scoped to
  `SddOrchestrator.Worker.CommandHandlingTest`.

  Mirrors the pattern `SddOrchestratorWeb.WorkerChannelEnvelopeSource`
  establishes for the same reason: the producing transactions that will own
  this content are not implemented yet, so the test scripts one envelope per
  command ID in the calling process. Defined locally rather than shared so
  this file's `mix test` invocation never depends on another test file being
  compiled alongside it.
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

defmodule SddOrchestrator.Worker.CommandHandlingTest do
  @moduledoc """
  Task 4 proof: the worker accepts commands and owns the attempt lease and
  durable run state.

  Covers [AC-06] (a start command for the current attempt is validated
  against that attempt, acknowledged exactly once, and an identical repeated
  command is acknowledged as a duplicate without executing again) and
  [AC-07] (a command naming a superseded attempt or carrying a stale fence
  token is refused with no process started, and any attempt already accepted
  under a superseded fence is recorded as stopped).

  The primary flows run over the real gateway: a real `Bandit` listener, the
  real `SddOrchestratorWeb.WorkerChannel`, the real `CommandOutbox`, and the
  real `SddOrchestrator.Worker.GatewayConnection` — exactly the pattern
  `SddOrchestrator.Worker.GatewayConnectionTest` establishes for Task 3,
  since `GatewayConnection` is a genuine wire-level Slipstream client with no
  fake-transport mode. The branch-level decisions that are only constructible
  by feeding `SddOrchestrator.Worker.CommandHandler` an envelope the real
  pipeline would never emit as a *second* delivery in the same test process
  (a stale fence, a mismatched manifest binding) are proven directly against
  that module instead of contorted through the socket.
  """

  use SddOrchestrator.DataCase, async: false

  import ExUnit.CaptureLog
  import SddOrchestrator.AccountsFixtures
  import SddOrchestrator.ProjectsFixtures

  alias SddOrchestrator.Accounts.DeviceWorkspace
  alias SddOrchestrator.Delivery.CommandOutbox
  alias SddOrchestrator.Delivery.CommandTransport.Channel, as: Transport
  alias SddOrchestrator.Delivery.ExecutionManifest
  alias SddOrchestrator.Delivery.RunAttempt
  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.DeliveryProtocolFixtures
  alias SddOrchestrator.Devices.Pairing
  alias SddOrchestrator.Portability.HostedLocalRepositoryBindings
  alias SddOrchestrator.Projects.Project
  alias SddOrchestrator.Repo
  alias SddOrchestrator.Worker.CommandHandler
  alias SddOrchestrator.Worker.CommandHandlingEnvelopeSource, as: EnvelopeSource
  alias SddOrchestrator.Worker.Configuration
  alias SddOrchestrator.Worker.GatewayConnection
  alias SddOrchestrator.Worker.RunState

  setup do
    on_exit(EnvelopeSource.install())

    bandit =
      start_supervised!(
        {Bandit, plug: SddOrchestratorWeb.Endpoint, scheme: :http, port: 0, startup_log: false}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    %{control_plane_address: "http://127.0.0.1:#{port}"}
  end

  describe "AC-06: a start command for the current attempt" do
    test "is validated, acknowledged exactly once, and durably recorded as accepted",
         %{control_plane_address: base} do
      %{project: project, feature: feature, run: run, credential: credential} =
        paired_and_bound_project()

      {command, envelope, _attempt} = enqueue_start(project, feature, run)
      EnvelopeSource.script(command.id, envelope)

      home = tmp_home()
      config = build_config(base, credential, project.id)
      {:ok, pid} = GatewayConnection.start_link(config, home: home)
      on_exit(fn -> stop_gateway(pid) end)

      wait_until(fn -> Transport.attached(project.id) != [] end)
      assert Transport.deliver(command) == :ok

      wait_until(fn -> acknowledged?(command.id) end)

      assert {:ok, recorded} = CommandOutbox.fetch(command.id)
      assert recorded.state == "acknowledged"
      assert recorded.result["status"] == "accepted"

      assert {:ok, %{current: current, previous: nil}} = RunState.load(home)
      assert current.command_id == command.id
      assert current.run_id == run.id
      assert current.attempt_number == 1
      assert current.fence_token == 1
      assert current.manifest_digest == command.manifest_digest
      assert current.lifecycle == "accepted"
    end

    test "a redelivery of the same command never changes the control plane's recorded result",
         %{control_plane_address: base} do
      %{project: project, feature: feature, run: run, credential: credential} =
        paired_and_bound_project()

      {command, envelope, _attempt} = enqueue_start(project, feature, run)
      EnvelopeSource.script(command.id, envelope)

      home = tmp_home()
      config = build_config(base, credential, project.id)
      {:ok, pid} = GatewayConnection.start_link(config, home: home)
      on_exit(fn -> stop_gateway(pid) end)

      wait_until(fn -> Transport.attached(project.id) != [] end)
      assert Transport.deliver(command) == :ok
      wait_until(fn -> acknowledged?(command.id) end)

      {:ok, first_recorded} = CommandOutbox.fetch(command.id)

      # The server-side outbox already absorbs a duplicate acknowledgement on
      # its own (`CommandOutbox.acknowledge/3` short-circuits once a command
      # is "acknowledged"); redelivering here proves the worker's own second
      # pass never disturbs that recorded result either, i.e. that nothing
      # observable changed as though the command executed a second time.
      assert Transport.deliver(command) == :ok
      Process.sleep(100)

      assert {:ok, second_recorded} = CommandOutbox.fetch(command.id)
      assert second_recorded.result == first_recorded.result
      assert second_recorded.acknowledged_at == first_recorded.acknowledged_at

      assert {:ok, %{current: current, previous: nil}} = RunState.load(home)
      assert current.command_id == command.id
    end
  end

  describe "CommandHandler: duplicate detection is the worker's own, not only the outbox's" do
    test "a second call for the same command_id answers duplicate without a second accepted transition" do
      home = tmp_home()
      {_command, envelope, _attempt} = fixture_command(attempt_number: 1, fence_token: 1)

      first = CommandHandler.handle_command(envelope, 1, home)
      assert first["status"] == "accepted"

      {:ok, %{current: accepted_once}} = RunState.load(home)

      second = CommandHandler.handle_command(envelope, 1, home)
      assert second["status"] == "duplicate"
      assert second["reason"] == nil
      assert second["command_id"] == envelope["command_id"]

      # No second "accepted" transition: the durable record is byte-for-byte
      # the same struct the first call produced.
      assert {:ok, %{current: ^accepted_once, previous: nil}} = RunState.load(home)
    end
  end

  describe "AC-07: a stale fence token or a superseded attempt is refused" do
    setup do
      home = tmp_home()

      current = %RunState{
        command_id: "cmd_current",
        operation: "start",
        project_id: DeliveryProtocolFixtures.project_id(),
        feature_id: DeliveryProtocolFixtures.feature_id(),
        run_id: DeliveryProtocolFixtures.run_id(),
        attempt_number: 2,
        fence_token: 2,
        manifest_digest: String.duplicate("a", 64),
        last_sequence: 0,
        agent_thread_ref: nil,
        lifecycle: "accepted"
      }

      :ok = RunState.store(%{current: current, previous: nil}, home)

      %{home: home, current: current}
    end

    test "a command carrying a stale fence token is refused and no work state advances", %{
      home: home,
      current: current
    } do
      {_command, envelope, _attempt} =
        fixture_command(
          command_id: "cmd_stale_fence",
          attempt_number: current.attempt_number,
          fence_token: current.fence_token - 1
        )

      ack = CommandHandler.handle_command(envelope, 1, home)

      assert ack["status"] == "rejected"
      assert ack["reason"] == "stale_fence_token"

      assert {:ok, %{current: ^current, previous: nil}} = RunState.load(home)
    end

    test "a command naming a superseded attempt is refused and no work state advances", %{
      home: home,
      current: current
    } do
      {_command, envelope, _attempt} =
        fixture_command(
          command_id: "cmd_superseded_attempt",
          attempt_number: current.attempt_number - 1,
          fence_token: current.fence_token
        )

      ack = CommandHandler.handle_command(envelope, 1, home)

      assert ack["status"] == "rejected"
      assert ack["reason"] == "superseded_attempt"

      assert {:ok, %{current: ^current, previous: nil}} = RunState.load(home)
    end
  end

  describe "AC-07: a newer command supersedes an older accepted attempt" do
    test "the older fence is recorded stopped and the newer one is accepted",
         %{control_plane_address: base} do
      %{project: project, feature: feature, run: run, credential: credential} =
        paired_and_bound_project()

      {first_command, first_envelope, first_attempt} = enqueue_start(project, feature, run)
      EnvelopeSource.script(first_command.id, first_envelope)

      home = tmp_home()
      config = build_config(base, credential, project.id)
      {:ok, pid} = GatewayConnection.start_link(config, home: home)
      on_exit(fn -> stop_gateway(pid) end)

      wait_until(fn -> Transport.attached(project.id) != [] end)
      assert Transport.deliver(first_command) == :ok
      wait_until(fn -> acknowledged?(first_command.id) end)

      assert {:ok, %{current: %{command_id: first_command_id}}} = RunState.load(home)
      assert first_command_id == first_command.id

      # A run's authoritative attempt lifecycle is the control plane's own —
      # only one attempt of a run may be current at a time (see
      # `SddOrchestrator.Delivery.RunAttempt`'s partial unique index) — so a
      # genuine second attempt first transitions the first one out of the
      # way, exactly like a real continuation would.
      Repo.update!(RunAttempt.transition_changeset(first_attempt, "superseded", 1))

      {second_command, second_envelope, _second_attempt} =
        enqueue_start(project, feature, run, attempt_number: 2, fence_token: 2)

      EnvelopeSource.script(second_command.id, second_envelope)

      assert Transport.deliver(second_command) == :ok
      wait_until(fn -> acknowledged?(second_command.id) end)

      assert {:ok, recorded} = CommandOutbox.fetch(second_command.id)
      assert recorded.result["status"] == "accepted"

      assert {:ok, %{current: current, previous: previous}} = RunState.load(home)

      assert current.command_id == second_command.id
      assert current.attempt_number == 2
      assert current.fence_token == 2
      assert current.lifecycle == "accepted"

      assert previous.command_id == first_command.id
      assert previous.attempt_number == 1
      assert previous.fence_token == 1
      assert previous.lifecycle == "stopped"
    end
  end

  describe "restart recovery" do
    test "durable run state survives a worker restart and the reloaded state still recognizes a redelivered command as a duplicate",
         %{control_plane_address: base} do
      %{project: project, feature: feature, run: run, credential: credential} =
        paired_and_bound_project()

      {command, envelope, _attempt} = enqueue_start(project, feature, run)
      EnvelopeSource.script(command.id, envelope)

      home = tmp_home()
      config = build_config(base, credential, project.id)

      {:ok, first_pid} = GatewayConnection.start_link(config, home: home)
      wait_until(fn -> Transport.attached(project.id) != [] end)
      assert Transport.deliver(command) == :ok
      wait_until(fn -> acknowledged?(command.id) end)

      assert {:ok, %{current: accepted_before_restart}} = RunState.load(home)
      assert accepted_before_restart.command_id == command.id

      # Simulate the worker process dying and a fresh one starting in its
      # place — a new pid, no shared in-memory state, only the same home
      # directory on disk.
      stop_gateway(first_pid)
      wait_until(fn -> Transport.attached(project.id) == [] end)

      {:ok, second_pid} = GatewayConnection.start_link(config, home: home)
      on_exit(fn -> stop_gateway(second_pid) end)
      wait_until(fn -> Transport.attached(project.id) != [] end)

      # The at-least-once redelivery lands on the restarted worker, which has
      # never held this command in memory — only what it reloads from disk.
      assert Transport.deliver(command) == :ok
      Process.sleep(100)

      assert {:ok, %{current: reloaded, previous: nil}} = RunState.load(home)
      assert reloaded == accepted_before_restart

      # The same envelope, handed directly to a fresh `CommandHandler` call
      # against that same reloaded home directory (no process, no memory at
      # all), answers exactly as it did before the restart: duplicate.
      ack = CommandHandler.handle_command(envelope, 1, home)
      assert ack["status"] == "duplicate"
    end
  end

  describe "manifest validation against the named attempt" do
    test "a manifest that does not bind to the attempt the envelope names is refused" do
      home = tmp_home()

      manifest =
        DeliveryProtocolFixtures.manifest(%{
          "attempt_number" => 1,
          "continuation" => %{"reason" => "initial", "prior_attempt_number" => nil}
        })

      # The envelope claims attempt 2 while the manifest it carries is bound
      # to attempt 1 — a mismatch the real pipeline's own `ProtocolCodec`
      # would already refuse before ever delivering it, and this worker
      # refuses independently rather than trusting the envelope blindly.
      envelope =
        DeliveryProtocolFixtures.command(%{
          "attempt_number" => 2,
          "fence_token" => 2,
          "manifest_digest" => ExecutionManifest.digest(manifest),
          "payload" => %{"manifest" => ExecutionManifest.to_map(manifest)}
        })

      ack = CommandHandler.handle_command(envelope, 1, home)

      assert ack["status"] == "rejected"
      assert ack["reason"] == "manifest_binding_mismatch"
      assert RunState.load(home) == {:ok, RunState.empty()}
    end

    test "a start command missing its manifest payload is refused" do
      home = tmp_home()

      envelope =
        DeliveryProtocolFixtures.command(%{"payload" => %{}})
        |> Map.put("manifest_digest", String.duplicate("a", 64))

      ack = CommandHandler.handle_command(envelope, 1, home)

      assert ack["status"] == "rejected"
      assert ack["reason"] == "manifest_absent"
    end
  end

  describe "an operation other than start" do
    test "is refused rather than crashing the gateway connection process",
         %{control_plane_address: base} do
      %{project: project, feature: feature, run: run, credential: credential} =
        paired_and_bound_project()

      {command, envelope} = enqueue_cancel(project, feature, run)
      EnvelopeSource.script(command.id, envelope)

      home = tmp_home()
      config = build_config(base, credential, project.id)

      log =
        capture_log(fn ->
          {:ok, pid} = GatewayConnection.start_link(config, home: home)
          on_exit(fn -> stop_gateway(pid) end)

          wait_until(fn -> Transport.attached(project.id) != [] end)
          assert Transport.deliver(command) == :ok
          wait_until(fn -> acknowledged?(command.id) end)

          assert Process.alive?(pid)
        end)

      refute log =~ "** (FunctionClauseError)"

      assert {:ok, recorded} = CommandOutbox.fetch(command.id)
      assert recorded.result["status"] == "rejected"
      assert recorded.result["reason"] =~ "operation_not_yet_supported"
      assert RunState.load(home) == {:ok, RunState.empty()}
    end

    test "CommandHandler answers rejected directly for cancel, resume, retry, and reconcile" do
      home = tmp_home()

      for operation <- ~w(cancel resume retry reconcile) do
        {_command, envelope, _attempt} = fixture_command(operation: operation)

        ack = CommandHandler.handle_command(envelope, 1, home)

        assert ack["status"] == "rejected"
        assert ack["reason"] =~ "operation_not_yet_supported"
      end

      assert RunState.load(home) == {:ok, RunState.empty()}
    end
  end

  # --- helpers -------------------------------------------------------------

  defp acknowledged?(command_id) do
    match?({:ok, %{state: "acknowledged"}}, CommandOutbox.fetch(command_id))
  end

  defp tmp_home do
    dir =
      Path.join(
        System.tmp_dir!(),
        "worker-command-handling-test-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp build_config(control_plane_address, worker_credential, project_id) do
    %Configuration{
      control_plane_address: control_plane_address,
      device_workspace_id: Ecto.UUID.generate(),
      worker_credential: worker_credential,
      agent_adapter: "claude_code",
      agent_executable: "/usr/local/bin/claude",
      workspace_root: System.tmp_dir!(),
      project_id: project_id
    }
  end

  # Unlinked first so this can be called mid-test (to simulate a worker
  # process restart) as well as from `on_exit`, without the linked process's
  # `:killed` exit reason propagating back and taking the test process down
  # with it.
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
        Process.sleep(20)
        do_wait_until(fun, deadline)
    end
  end

  # Builds a real run/attempt/manifest/command bound together, enqueues the
  # command in the durable outbox, and returns the protocol envelope for it —
  # the same shape `SddOrchestrator.Delivery.CommandTransport.Channel` would
  # deliver to an attached worker.
  defp enqueue_start(project, feature, run, attrs \\ []) do
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

  # A self-contained envelope for tests that call `CommandHandler` directly
  # and never touch the database or the real channel.
  defp fixture_command(attrs) do
    attrs = Map.new(attrs)
    operation = Map.get(attrs, :operation, "start")
    attempt_number = Map.get(attrs, :attempt_number, 1)
    fence_token = Map.get(attrs, :fence_token, attempt_number)

    manifest =
      DeliveryProtocolFixtures.manifest(%{
        "attempt_number" => attempt_number,
        "continuation" =>
          if(attempt_number == 1,
            do: %{"reason" => "initial", "prior_attempt_number" => nil},
            else: %{"reason" => "automatic_retry", "prior_attempt_number" => attempt_number - 1}
          )
      })

    base =
      DeliveryProtocolFixtures.command(%{
        "command_id" => Map.get(attrs, :command_id, "cmd_#{System.unique_integer([:positive])}"),
        "operation" => operation,
        "attempt_number" => attempt_number,
        "fence_token" => fence_token,
        "manifest_digest" => ExecutionManifest.digest(manifest),
        "payload" => %{"manifest" => ExecutionManifest.to_map(manifest)}
      })

    envelope =
      if operation == "start" do
        base
      else
        Map.put(base, "payload", %{})
      end

    {nil, envelope, nil}
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
        os_major: "15",
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
