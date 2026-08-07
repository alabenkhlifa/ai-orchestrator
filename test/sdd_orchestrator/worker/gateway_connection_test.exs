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
  """

  use SddOrchestrator.DataCase, async: false

  import ExUnit.CaptureLog
  import SddOrchestrator.AccountsFixtures
  import SddOrchestrator.ProjectsFixtures

  alias SddOrchestrator.Accounts.DeviceWorkspace
  alias SddOrchestrator.Delivery.CommandTransport.Channel, as: Transport
  alias SddOrchestrator.Delivery.WorkerProtocol
  alias SddOrchestrator.Devices.Pairing
  alias SddOrchestrator.Portability.HostedLocalRepositoryBindings
  alias SddOrchestrator.Projects.Project
  alias SddOrchestrator.Repo
  alias SddOrchestrator.Worker.Configuration
  alias SddOrchestrator.Worker.GatewayConnection

  setup do
    # Started via `start_supervised!/1` (not a bare `Bandit.start_link/1` plus
    # a manual `on_exit`) so ExUnit's own per-test supervisor owns shutdown
    # ordering; a directly-linked Bandit supervisor stopped from `on_exit`
    # races the already-exited test process and raises on teardown.
    bandit =
      start_supervised!(
        {Bandit, plug: SddOrchestratorWeb.Endpoint, scheme: :http, port: 0, startup_log: false}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

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

  defp count_messages(message, acc \\ 0) do
    receive do
      ^message -> count_messages(message, acc + 1)
    after
      0 -> acc
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
