defmodule SddOrchestrator.Worker.GatewayConnectionTest do
  @moduledoc """
  Task 3 proof: the worker dials the control plane's real `/worker` gateway
  (`SddOrchestratorWeb.WorkerSocket` and `SddOrchestratorWeb.WorkerChannel`)
  over an actual listening websocket — never Phoenix.ChannelTest's in-process
  fake transport, since `SddOrchestrator.Worker.GatewayConnection` is a real
  wire-level Slipstream client and there is no fake-transport mode for it.

  A dedicated `Bandit` listener, bound to the already-running
  `SddOrchestratorWeb.Endpoint` on an OS-assigned port, gives each test a real
  TCP listener without touching `config/test.exs`'s `server: false`.

  Covers [AC-04] (joins with a supported version and the full capability set,
  becomes reachable, reconnect rejoins the same topic without a new
  credential) and [AC-05] (an unsupported version or a withheld required
  capability is reported to the operator and not retried as a success).

  specs/39-mac-scoped-worker-connection Task 7 adds [AC-07] (a connected
  transport the control plane has not attached does not read as connected) and
  [AC-08] (a refused attachment is named as a refusal, never presented as a
  connection), both over the same real listener and the same real channels.
  """

  use SddOrchestrator.DataCase, async: false

  import ExUnit.CaptureLog
  import SddOrchestrator.AccountsFixtures
  import SddOrchestrator.ProjectsFixtures

  alias SddOrchestrator.Accounts.DeviceWorkspace
  alias SddOrchestrator.Delivery.CommandTransport.Channel, as: Transport
  alias SddOrchestrator.Delivery.WorkerAttachment
  alias SddOrchestrator.Delivery.WorkerProtocol
  alias SddOrchestrator.Devices.Pairing
  alias SddOrchestrator.Portability.HostedLocalRepositoryBindings
  alias SddOrchestrator.Projects.Project
  alias SddOrchestrator.Repo
  alias SddOrchestrator.Worker.Configuration
  alias SddOrchestrator.Worker.ConnectionStatus
  alias SddOrchestrator.Worker.GatewayConnection

  setup do
    # [specs/43 Task 2] `ConnectionStatus` now publishes every transition to a
    # file under `Configuration.home/1`. These tests drive the real callbacks,
    # so without redirecting the home they would write into the developer's own
    # `~/.sdd_orchestrator/worker` and could disturb a worker actually running
    # on this machine.
    worker_home =
      Path.join(System.tmp_dir!(), "sdd_worker_home_#{System.unique_integer([:positive])}")

    File.mkdir_p!(worker_home)
    previous_home = Application.get_env(:sdd_orchestrator, :worker_home)
    Application.put_env(:sdd_orchestrator, :worker_home, worker_home)

    on_exit(fn ->
      if previous_home do
        Application.put_env(:sdd_orchestrator, :worker_home, previous_home)
      else
        Application.delete_env(:sdd_orchestrator, :worker_home)
      end

      File.rm_rf!(worker_home)
    end)

    # Started via `start_supervised!/1` (not a bare `Bandit.start_link/1` plus
    # a manual `on_exit`) so ExUnit's own per-test supervisor owns shutdown
    # ordering; a directly-linked Bandit supervisor stopped from `on_exit`
    # races the already-exited test process and raises on teardown.
    bandit =
      start_supervised!(
        {Bandit, plug: SddOrchestratorWeb.Endpoint, scheme: :http, port: 0, startup_log: false}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    # Every test here drives the real callbacks that write `ConnectionStatus`,
    # which is `:persistent_term`-backed and therefore VM-global. Clearing it
    # on both sides gives each test the genuine "nothing observed yet" reading
    # and leaves nothing behind for another module to read.
    reset_connection_status()
    on_exit(&reset_connection_status/0)

    %{control_plane_address: "http://127.0.0.1:#{port}"}
  end

  describe "AC-04: joining the execution target's topic" do
    test "joins with the full capability set and a supported version, and becomes reachable",
         %{control_plane_address: base} do
      %{project: project, credential: credential} = paired_and_bound_project()
      config = build_config(base, credential, project.id)

      {:ok, pid} = GatewayConnection.start_link(config)
      on_exit(fn -> stop_gateway(pid) end)

      wait_until(fn -> Transport.attached(project.id) != [] end)

      assert [{_worker_pid, contract}] = Transport.attached(project.id)
      assert contract.protocol_version == WorkerProtocol.version()
      assert contract.capabilities == WorkerProtocol.capabilities()
    end

    test "a dropped connection reconnects and rejoins the same topic without a new gateway credential",
         %{control_plane_address: base} do
      %{project: project, credential: credential} = paired_and_bound_project()
      config = build_config(base, credential, project.id)

      handler_id = {:gateway_credential_requests, make_ref()}
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:phoenix, :endpoint, :stop],
        fn _event, _measurements, %{conn: conn}, _config ->
          if conn.request_path == "/worker/gateway_credentials" do
            send(test_pid, :gateway_credential_request)
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      {:ok, pid} = GatewayConnection.start_link(config)
      on_exit(fn -> stop_gateway(pid) end)

      wait_until(fn -> Transport.attached(project.id) != [] end)
      assert [{first_worker_pid, first_contract}] = Transport.attached(project.id)
      assert count_messages(:gateway_credential_request) == 1

      force_transport_drop(pid)

      wait_until(fn ->
        match?(
          [{worker_pid, _contract}] when worker_pid != first_worker_pid,
          Transport.attached(project.id)
        )
      end)

      assert [{second_worker_pid, second_contract}] = Transport.attached(project.id)
      assert second_worker_pid != first_worker_pid

      # Same topic (same project), same negotiated contract — no widened
      # authorization on rejoin.
      assert second_contract.protocol_version == first_contract.protocol_version
      assert second_contract.capabilities == first_contract.capabilities

      # No second call to the gateway-credential exchange: the reconnect
      # reused the already-obtained token embedded in the retained connection
      # URI, exactly like `Slipstream.reconnect/1` is documented to do.
      assert count_messages(:gateway_credential_request) == 0
    end
  end

  describe "AC-05: refusal is reported and not retried as connected" do
    test "an unsupported protocol version is refused, logged with its reason, and not rejoined",
         %{control_plane_address: base} do
      %{project: project, credential: credential} = paired_and_bound_project()
      config = build_config(base, credential, project.id)

      log =
        capture_log(fn ->
          {:ok, pid} = GatewayConnection.start_link(config, protocol_version: 999)
          on_exit(fn -> stop_gateway(pid) end)
          Process.sleep(500)
        end)

      assert log =~ "JOIN REFUSED"
      assert log =~ "unsupported_protocol_version"
      assert log =~ "not retrying"
      assert Transport.attached(project.id) == []
    end

    test "a withheld required capability is refused, logged with its reason, and not rejoined",
         %{control_plane_address: base} do
      %{project: project, credential: credential} = paired_and_bound_project()
      config = build_config(base, credential, project.id)
      partial_capabilities = List.delete(GatewayConnection.capabilities(), "run.start")

      log =
        capture_log(fn ->
          {:ok, pid} = GatewayConnection.start_link(config, capabilities: partial_capabilities)
          on_exit(fn -> stop_gateway(pid) end)
          Process.sleep(500)
        end)

      assert log =~ "JOIN REFUSED"
      assert log =~ "missing_required_capability"
      assert log =~ "not retrying"
      assert Transport.attached(project.id) == []
    end
  end

  describe "AC-07/AC-08: connected means the control plane attached this worker" do
    test "a projectless worker attaches for its Mac and only then reads as connected",
         %{control_plane_address: base} do
      %{device_workspace: device_workspace, worker: worker, credential: credential} =
        paired_workspace_worker()

      config = build_workspace_config(base, credential, device_workspace.id, worker.id)

      # Nothing observed yet, and nothing may claim otherwise.
      assert ConnectionStatus.status().status == :unknown

      {:ok, pid} = GatewayConnection.start_link(config)
      on_exit(fn -> stop_gateway(pid) end)

      wait_until(fn -> WorkerAttachment.attached(device_workspace.id) != [] end)

      assert [{_channel_pid, contract}] = WorkerAttachment.attached(device_workspace.id)
      assert contract.worker_id == worker.id
      assert contract.protocol_version == WorkerProtocol.version()
      assert contract.capabilities == WorkerProtocol.capabilities()

      wait_until(fn -> ConnectionStatus.status().status == :connected end)

      # Connected is only ever written with an attachment standing behind it.
      assert WorkerAttachment.attached(device_workspace.id) != []
    end

    test "the gateway-credential request for a projectless worker omits project_id entirely",
         %{control_plane_address: base} do
      %{device_workspace: device_workspace, worker: worker, credential: credential} =
        paired_workspace_worker()

      config = build_workspace_config(base, credential, device_workspace.id, worker.id)

      # This asserts on the request the controller actually received, not on
      # the outcome: the endpoint's own `:stop` telemetry carries the parsed
      # body, so an absent key and a `nil` one are told apart directly rather
      # than inferred from the exchange succeeding.
      handler_id = {:gateway_credential_bodies, make_ref()}
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:phoenix, :endpoint, :stop],
        fn _event, _measurements, %{conn: conn}, _config ->
          if conn.request_path == "/worker/gateway_credentials" do
            send(test_pid, {:gateway_credential_body, conn.body_params})
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      {:ok, pid} = GatewayConnection.start_link(config)
      on_exit(fn -> stop_gateway(pid) end)

      assert_receive {:gateway_credential_body, body}, 3_000
      refute Map.has_key?(body, "project_id")
      assert body == %{}

      # And the exchange the omission unlocks really did produce a usable
      # credential, so the worker reaches an attachment.
      wait_until(fn -> WorkerAttachment.attached(device_workspace.id) != [] end)
    end

    test "a connected transport whose join is refused reads as refused, never as connected",
         %{control_plane_address: base} do
      %{device_workspace: device_workspace, worker: worker, credential: credential} =
        paired_workspace_worker()

      config = build_workspace_config(base, credential, device_workspace.id, worker.id)

      # The "transport connected" line is `Logger.info`, and `config/test.exs`
      # runs the logger at `:warning`, so the primary level is lifted for this
      # one test and restored after it. Without it the event never reaches
      # `capture_log`'s handler at all, and the proof that the socket really
      # came up would be missing.
      previous_level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: previous_level) end)

      log =
        capture_log(fn ->
          {:ok, pid} = GatewayConnection.start_link(config, protocol_version: 999)
          on_exit(fn -> stop_gateway(pid) end)
          Process.sleep(500)
        end)

      # The transport genuinely came up: this is a connected socket the control
      # plane attached nothing for.
      assert log =~ "transport connected for device workspace #{device_workspace.id}"
      assert log =~ "not attached until the join is accepted"
      assert log =~ "JOIN REFUSED"
      assert log =~ "unsupported_protocol_version"
      assert WorkerAttachment.attached(device_workspace.id) == []

      refused = ConnectionStatus.status()
      assert refused.status == :refused
      assert refused.reason == "unsupported_protocol_version"

      # Reported once, and not retried as though it had succeeded: nothing
      # attaches later and the reading never turns into a connection.
      assert log |> String.split("JOIN REFUSED") |> length() == 2
      assert log =~ "not retrying"

      Process.sleep(300)
      assert ConnectionStatus.status().status == :refused
      assert WorkerAttachment.attached(device_workspace.id) == []
    end

    test "a lost attachment stops reading as connected while the transport is still up",
         %{control_plane_address: base} do
      %{device_workspace: device_workspace, worker: worker, credential: credential} =
        paired_workspace_worker()

      config = build_workspace_config(base, credential, device_workspace.id, worker.id)

      {:ok, pid} = GatewayConnection.start_link(config)
      on_exit(fn -> stop_gateway(pid) end)

      wait_until(fn -> ConnectionStatus.status().status == :connected end)
      assert [{channel_pid, _contract}] = WorkerAttachment.attached(device_workspace.id)

      # Killing the control-plane channel loses the attachment without
      # dropping the websocket. Slipstream schedules the rejoin at least
      # `rejoin_after_msec` (100ms) later, so the window this samples is a
      # real interval the library guarantees, not a race.
      ref = Process.monitor(channel_pid)
      Process.exit(channel_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^channel_pid, _reason}, 1_000

      wait_until(fn -> ConnectionStatus.status().status != :connected end, 1_000, 5)
      assert ConnectionStatus.status().status == :disconnected

      # The rejoin then re-attaches, and only that turns the reading back into
      # a connection.
      wait_until(fn -> ConnectionStatus.status().status == :connected end)
      assert WorkerAttachment.attached(device_workspace.id) != []
    end
  end

  describe "Task 9: retrying an unreachable control plane (device-workspace scope only)" do
    test "a device-workspace worker retries the credential exchange with a widening delay, never stopping",
         %{} do
      %{device_workspace: device_workspace, worker: worker, credential: credential} =
        paired_workspace_worker()

      # Port 1 is privileged; nothing in this suite (or on a normal
      # developer machine) ever listens there, so every POST to
      # `/worker/gateway_credentials` is refused by the OS immediately —
      # a transport error (connection refused), never an HTTP status.
      config =
        build_workspace_config("http://127.0.0.1:1", credential, device_workspace.id, worker.id)

      {pid, log} =
        with_log(fn ->
          {:ok, pid} =
            GatewayConnection.start_link(config,
              gateway_credential_retry_after_msec: [10, 20, 30]
            )

          on_exit(fn -> stop_gateway(pid) end)

          # Long enough, at this fast injected backoff, for several scheduled
          # retries to have already fired.
          Process.sleep(300)

          pid
        end)

      assert Process.alive?(pid)
      assert ConnectionStatus.status().status == :disconnected
      refute log =~ "refused to start"
      # At least two retry warnings: `String.split/2` on N occurrences of the
      # separator yields N + 1 parts (mirrors this file's own `JOIN REFUSED`
      # count assertion above).
      assert log |> String.split("retrying in") |> length() >= 3
    end

    # Bringing the setup fixture's own Bandit listener "up after a delay" is
    # impractical: it is already started (and already reachable) before this
    # test body ever runs, via `start_supervised!/1` in `setup`. Sending the
    # process a fabricated `:retry_connect_gateway` while already attached
    # (the brief's other suggested fallback) would exercise `establish/2`
    # racing an already-open Slipstream transport — behavior this task's
    # brief does not specify and that risks a false pass. So this test
    # instead gives the worker its own address, on a specific (not
    # OS-assigned) port that is genuinely unbound when `start_link/2` is
    # called, and only starts a real `Bandit` listener on that same port
    # after a delay — a real, honest "the control plane becomes reachable
    # later" transition, proven through the same `pid` throughout.
    test "the same process attaches once an initially-unreachable control plane comes up",
         %{} do
      %{device_workspace: device_workspace, worker: worker, credential: credential} =
        paired_workspace_worker()

      port = reserve_port()
      control_plane_address = "http://127.0.0.1:#{port}"

      config =
        build_workspace_config(control_plane_address, credential, device_workspace.id, worker.id)

      {:ok, pid} =
        GatewayConnection.start_link(config, gateway_credential_retry_after_msec: [20])

      on_exit(fn -> stop_gateway(pid) end)

      # A few failed attempts happen first, against the still-unbound port.
      Process.sleep(80)
      assert Process.alive?(pid)
      assert ConnectionStatus.status().status == :disconnected
      assert WorkerAttachment.attached(device_workspace.id) == []

      start_supervised!(
        {Bandit, plug: SddOrchestratorWeb.Endpoint, scheme: :http, port: port, startup_log: false}
      )

      wait_until(fn -> ConnectionStatus.status().status == :connected end)

      # Never restarted: the process this test started is the one that
      # attached.
      assert Process.alive?(pid)
      assert [{_channel_pid, contract}] = WorkerAttachment.attached(device_workspace.id)
      assert contract.worker_id == worker.id
    end

    test "a genuinely refused credential (not a transport error) still stops the process",
         %{control_plane_address: base} do
      %{device_workspace: device_workspace, worker: worker} = paired_workspace_worker()

      # An unrecognized worker credential is rejected by
      # `WorkerGatewayCredentialController` with a 403 — a bad HTTP status,
      # not an absent response, so `fetch_gateway_credential/1` returns
      # `:gateway_credential_refused`, never `:gateway_credential_transport_error`.
      # The address itself is the real, reachable listener from `setup`.
      config =
        build_workspace_config(
          base,
          "not-a-real-worker-credential",
          device_workspace.id,
          worker.id
        )

      log =
        capture_log(fn ->
          {:ok, pid} = GatewayConnection.start_link(config)
          on_exit(fn -> stop_gateway(pid) end)

          ref = Process.monitor(pid)
          assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2_000
          refute Process.alive?(pid)
        end)

      assert log =~ "worker gateway refused to start for device workspace #{device_workspace.id}"
      refute log =~ "retrying in"
    end

    test "a project-scoped worker still stops immediately when the control plane is unreachable (regression)",
         %{} do
      %{project: project, credential: credential} = paired_and_bound_project()

      # Same reliably-refused address as the device-workspace test above.
      config = build_config("http://127.0.0.1:1", credential, project.id)

      log =
        capture_log(fn ->
          {:ok, pid} = GatewayConnection.start_link(config)
          on_exit(fn -> stop_gateway(pid) end)

          ref = Process.monitor(pid)
          assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2_000
          refute Process.alive?(pid)
        end)

      assert log =~ "worker gateway refused to start for project #{project.id}"
      refute log =~ "retrying in"
    end
  end

  describe "the hardcoded protocol contract" do
    test "matches SddOrchestrator.Delivery.WorkerProtocol exactly" do
      assert GatewayConnection.protocol_version() == WorkerProtocol.version()
      assert GatewayConnection.capabilities() == WorkerProtocol.capabilities()
    end
  end

  # --- helpers -----------------------------------------------------------

  defp build_config(control_plane_address, worker_credential, project_id) do
    %Configuration{
      control_plane_address: control_plane_address,
      device_workspace_id: Ecto.UUID.generate(),
      worker_credential: worker_credential,
      agent_adapter: "claude_code",
      agent_executable: "/usr/local/bin/claude",
      workspace_root: System.tmp_dir!(),
      project_id: project_id,
      worker_id: Ecto.UUID.generate()
    }
  end

  # A worker paired from the Mac app: authorized for its device workspace,
  # with no project and no repository folder yet.
  defp build_workspace_config(
         control_plane_address,
         worker_credential,
         device_workspace_id,
         worker_id
       ) do
    %Configuration{
      control_plane_address: control_plane_address,
      device_workspace_id: device_workspace_id,
      worker_credential: worker_credential,
      agent_adapter: "claude_code",
      agent_executable: "/usr/local/bin/claude",
      worker_id: worker_id
    }
  end

  # The key is `ConnectionStatus`'s own private one, restated here because
  # erasing it is the only way back to the genuine "nothing observed yet"
  # reading; the module exposes writers, not a reset.
  defp reset_connection_status do
    :persistent_term.erase({ConnectionStatus, :status})
    :ok
  end

  defp stop_gateway(pid) do
    if Process.alive?(pid) do
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
  # `GatewayConnection` — a genuine transport-level close, not a simulated
  # event, exercised through the library's own public command path.
  defp force_transport_drop(pid) do
    socket = :sys.get_state(pid)
    Slipstream.disconnect(socket)
    :ok
  end

  # Task 9: hands back an OS-assigned port that is free *right now*, for a
  # test that needs to name a specific port before anything binds it (rather
  # than `port: 0`, which only reveals the port after something is already
  # listening on it). Immediately releasing it leaves a real, if short, race
  # with anything else on the machine — acceptable for this suite's own
  # serial (`async: false`) module.
  defp reserve_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp count_messages(message, acc \\ 0) do
    receive do
      ^message -> count_messages(message, acc + 1)
    after
      0 -> acc
    end
  end

  # `interval` is optional and defaults to the original 20ms, so every existing
  # caller is unchanged; a shorter one is used only where the window being
  # sampled is short and library-guaranteed.
  defp wait_until(fun, timeout \\ 3_000, interval \\ 20) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(fun, deadline, interval)
  end

  defp do_wait_until(fun, deadline, interval) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition not met within timeout")

      true ->
        Process.sleep(interval)
        do_wait_until(fun, deadline, interval)
    end
  end

  defp paired_and_bound_project do
    account = account_fixture()
    personal_workspace = workspace_fixture(account)
    device_workspace = %DeviceWorkspace{id: Ecto.UUID.generate()}
    project = local_project_fixture(personal_workspace, portable_identifier())

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
      worker: worker,
      credential: credential,
      device_workspace: device_workspace,
      binding: binding
    }
  end

  defp paired_workspace_worker do
    device_workspace = %DeviceWorkspace{id: Ecto.UUID.generate()}
    {worker, credential} = available_worker_fixture(device_workspace)

    %{device_workspace: device_workspace, worker: worker, credential: credential}
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
