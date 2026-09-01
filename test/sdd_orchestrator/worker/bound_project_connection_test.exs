defmodule SddOrchestrator.Worker.BoundProjectEnvelopeSource do
  @moduledoc """
  Supplies the protocol envelope a durable command is delivered as, scoped to
  `SddOrchestrator.Worker.BoundProjectConnectionTest`.

  Mirrors the pattern every other worker integration test file already
  establishes, defined locally so this file's `mix test` invocation never
  depends on another test file being compiled alongside it.
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

defmodule SddOrchestrator.Worker.BoundProjectConnectionTest do
  @moduledoc """
  specs/41-feature-delivery-from-the-ui Task 7 proof: the worker-runtime half.

  A worker paired from the menu bar is authorized for its Mac and joins no
  project, so a command for a project it was bound to reaches nobody. These
  tests drive that whole answer against the real control plane over a real
  socket: a dedicated `Bandit` listener bound to the already-running
  `SddOrchestratorWeb.Endpoint` on an OS-assigned port, exactly as
  `SddOrchestrator.Worker.GatewayConnectionTest` does. `GatewayConnection` is a
  wire-level Slipstream client with no fake-transport mode, so anything less
  would prove something other than what the slice claims.

  What is proved here is that the notice turns into a real, ordinary project
  connection: it exchanges the project credential, joins `worker:<project id>`,
  lands in the project-keyed registry, and a claimed command delivered through
  `CommandTransport.Channel.deliver/1` reaches it and is acknowledged. Losing
  the binding closes it again, and a repeated notice for a project already
  served opens nothing.

  `async: false`: a real listener, the node-wide registries, and the
  application-level envelope source are all shared.
  """

  use SddOrchestrator.DataCase, async: false

  import ExUnit.CaptureLog
  import SddOrchestrator.AccountsFixtures
  import SddOrchestrator.ProjectsFixtures

  alias SddOrchestrator.Accounts.DeviceWorkspace
  alias SddOrchestrator.Delivery.BoundProjectNotice
  alias SddOrchestrator.Delivery.CommandOutbox
  alias SddOrchestrator.Delivery.CommandTransport.Channel, as: Transport
  alias SddOrchestrator.Delivery.WorkerAttachment
  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.DeliveryProtocolFixtures
  alias SddOrchestrator.Devices.Pairing
  alias SddOrchestrator.Portability.HostedLocalRepositoryBindings
  alias SddOrchestrator.Portability.HostedLocalRepositoryConnection
  alias SddOrchestrator.Projects.Project
  alias SddOrchestrator.Worker.BoundProjectEnvelopeSource, as: EnvelopeSource
  alias SddOrchestrator.Worker.Configuration
  alias SddOrchestrator.Worker.ConnectionStatus
  alias SddOrchestrator.Worker.GatewayConnection

  setup do
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

    on_exit(EnvelopeSource.install())

    bandit =
      start_supervised!(
        {Bandit, plug: SddOrchestratorWeb.Endpoint, scheme: :http, port: 0, startup_log: false}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    # This worker's own project-connection supervisor, named per test so a file
    # running beside another never adopts its connections.
    supervisor =
      start_supervised!(
        {SddOrchestrator.Worker.ProjectConnections,
         [name: :"project_connections_#{System.unique_integer([:positive])}"]}
      )

    reset_connection_status()
    on_exit(&reset_connection_status/0)

    %{
      control_plane_address: "http://127.0.0.1:#{port}",
      home: worker_home,
      supervisor: supervisor
    }
  end

  describe "a project the Mac was told to serve" do
    test "is joined on its own topic, registered, and reachable by command delivery",
         context do
      project = paired_project(context)

      {:ok, _binding} = bind(project)
      pid = start_mac_connection(project, context)

      # The Mac attachment is the only thing the configuration authorized.
      wait_until(fn -> WorkerAttachment.attached(project.device_workspace.id) != [] end)

      # And the project connection the notice opened, which is an ordinary
      # project-scoped one: same topic, same registry, same contract.
      wait_until(fn -> Transport.attached(project.project.id) != [] end)

      assert [{_channel, contract}] = Transport.attached(project.project.id)
      assert contract.worker_id == project.worker.id

      # Nothing about delivery changed, so a claimed command must simply arrive.
      {command, envelope} = enqueue_reconcile(project)
      EnvelopeSource.script(command.id, envelope)

      assert Transport.deliver(command) == :ok
      wait_until(fn -> acknowledged?(command.id) end)

      assert Process.alive?(pid)
    end

    test "is dropped when the project stops being the Mac's", context do
      project = paired_project(context)

      {:ok, _binding} = bind(project)
      _pid = start_mac_connection(project, context)

      wait_until(fn -> Transport.attached(project.project.id) != [] end)

      assert {:ok, :disconnected} =
               HostedLocalRepositoryBindings.disconnect(
                 project.personal_workspace,
                 project.project.id
               )

      wait_until(fn -> Transport.attached(project.project.id) == [] end)
      wait_until(fn -> DynamicSupervisor.count_children(context.supervisor).active == 0 end)

      # The Mac attachment is untouched: losing one project is not losing the
      # machine.
      assert WorkerAttachment.attached(project.device_workspace.id) != []
    end

    test "is opened once, however many times the Mac is told about it", context do
      project = paired_project(context)

      {:ok, _binding} = bind(project)
      _pid = start_mac_connection(project, context)

      wait_until(fn -> Transport.attached(project.project.id) != [] end)

      # The repeat, and then a notice for a second project. Both travel the same
      # channel, socket, and connection in order, so the second one arriving is
      # proof the repeat was already handled. That is what makes the counts
      # below a real check rather than a race.
      BoundProjectNotice.bound(project.device_workspace.id, project.project.id)

      second = second_project(project)
      {:ok, _binding} = bind(second)

      wait_until(fn -> Transport.attached(second.project.id) != [] end)

      assert length(Transport.attached(project.project.id)) == 1
      assert length(Transport.attached(second.project.id)) == 1
      assert DynamicSupervisor.count_children(context.supervisor).active == 2
    end

    test "that cannot be opened costs the Mac neither its connection nor its credential",
         context do
      project = paired_project(context)

      # Nothing is running under this name, so the open fails the way a broken
      # worker installation would rather than the way a test double would.
      pid = start_mac_connection(project, %{context | supervisor: :no_such_supervisor})

      wait_until(fn -> WorkerAttachment.attached(project.device_workspace.id) != [] end)
      ref = Process.monitor(pid)

      log =
        capture_log(fn ->
          {:ok, _binding} = bind(project)

          # One project failing to open must not take the Mac connection with
          # it, or the worker would lose every other project and its own
          # liveness along with the one that failed.
          refute_receive {:DOWN, ^ref, :process, ^pid, _reason}, 500
        end)

      assert Process.alive?(pid)
      assert WorkerAttachment.attached(project.device_workspace.id) != []
      assert Transport.attached(project.project.id) == []

      assert log =~ "could not open a project connection for project #{project.project.id}"

      # The refusal quotes the failed start call, and that call carries this
      # worker's whole configuration, so what is logged is named rather than
      # inspected.
      refute log =~ project.credential
    end
  end

  # --- the worker ---------------------------------------------------------

  # Exactly what `MacPairingRetention` stores for a menu-bar pairing: no
  # project, and no repository folder. Every project connection this worker
  # opens is opened because it was told to, never because it was configured.
  defp start_mac_connection(project, context) do
    config = %Configuration{
      control_plane_address: context.control_plane_address,
      device_workspace_id: project.device_workspace.id,
      worker_credential: project.credential,
      agent_adapter: "claude_code",
      agent_executable: "/usr/local/bin/claude",
      worker_id: project.worker.id
    }

    {:ok, pid} =
      GatewayConnection.start_link(config,
        home: context.home,
        project_connections: context.supervisor
      )

    on_exit(fn -> stop_gateway(pid) end)

    pid
  end

  # --- fixtures -----------------------------------------------------------

  defp paired_project(_context) do
    account = account_fixture()
    personal_workspace = workspace_fixture(account)
    device_workspace = %DeviceWorkspace{id: Ecto.UUID.generate()}
    project = local_project_fixture(personal_workspace, portable_identifier())
    feature = DeliveryFixtures.feature_fixture(project, account)
    run = DeliveryFixtures.run_fixture(project, feature)
    {worker, credential} = available_worker_fixture(device_workspace)

    %{
      account: account,
      personal_workspace: personal_workspace,
      device_workspace: device_workspace,
      project: project,
      feature: feature,
      run: run,
      worker: worker,
      credential: credential
    }
  end

  # A second project on the same Mac and the same worker, which is what a
  # person with two repositories on one machine actually has.
  defp second_project(project) do
    %{
      project
      | project: local_project_fixture(project.personal_workspace, portable_identifier())
    }
  end

  defp bind(project) do
    HostedLocalRepositoryConnection.connect(
      project.personal_workspace,
      project.project.id,
      project.device_workspace,
      project.worker.id,
      fn _repository_id -> {:ok, true} end
    )
  end

  # `reconcile` is the lightest command the protocol defines: it carries no
  # manifest, changes nothing, and is always accepted, so what it proves is
  # exactly the one thing under test here, that delivery reached the worker.
  defp enqueue_reconcile(project) do
    {:ok, command} =
      CommandOutbox.enqueue(%{
        id: Ecto.UUID.generate(),
        project_id: project.project.id,
        run_id: project.run.id,
        operation: "reconcile",
        expected_state_version: project.run.state_version
      })

    envelope =
      DeliveryProtocolFixtures.command(%{
        "command_id" => command.id,
        "project_id" => project.project.id,
        "feature_id" => project.feature.id,
        "run_id" => project.run.id,
        "operation" => "reconcile",
        "expected_state_version" => command.expected_state_version,
        "payload" => %{}
      })

    {command, envelope}
  end

  defp acknowledged?(command_id),
    do: match?({:ok, %{state: "acknowledged"}}, CommandOutbox.fetch(command_id))

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
    {:ok, %{code: code}} = Pairing.start_pairing(device_workspace.id)

    {:ok, %{worker: worker, credential: credential}} =
      Pairing.complete_pairing(code, %{
        os_family: "macos",
        os_major: "26",
        app_version: "1.0.0",
        protocol_version: "1"
      })

    {:ok, worker} = Pairing.mark_seen(worker)
    {worker, credential}
  end

  defp portable_identifier do
    salt = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    digest = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    "local-repo:v1:#{salt}:#{digest}"
  end

  # --- helpers ------------------------------------------------------------

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

  defp wait_until(fun, timeout \\ 5_000, interval \\ 20) do
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
end
