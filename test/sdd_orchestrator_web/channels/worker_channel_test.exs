defmodule SddOrchestratorWeb.WorkerChannelEnvelopeSource do
  @moduledoc """
  Supplies the protocol envelope a durable command is delivered as.

  The producing transactions that will own this content are not implemented
  yet, so the test scripts one envelope per command ID in the calling process.
  """
  @behaviour SddOrchestrator.Delivery.CommandTransport.EnvelopeSource

  @key {__MODULE__, :envelopes}

  @doc "Installs this source for one test and returns its restore function."
  def install do
    original = Application.get_env(:sdd_orchestrator, :command_envelope_source)
    Application.put_env(:sdd_orchestrator, :command_envelope_source, __MODULE__)
    Process.put(@key, %{})

    fn -> Application.put_env(:sdd_orchestrator, :command_envelope_source, original) end
  end

  @doc "Scripts the envelope one command is delivered as."
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

defmodule SddOrchestratorWeb.WorkerChannelTest do
  @moduledoc """
  Proof for the authenticated worker gateway (Task 19).

  The properties under test are the ones that decide whether a worker may act
  at all: a connection is authenticated for exactly one execution target, a
  join cannot reach another project, an incompatible contract is refused before
  any command can be delivered, a claimed command reaches only a compatible
  attached worker, and every inbound frame is refused whole when the shared
  codec rejects it.
  """
  use SddOrchestrator.DataCase, async: false

  import Phoenix.ChannelTest, except: [join: 2, join: 3, join: 4]

  alias Phoenix.PubSub
  alias SddOrchestrator.Delivery.CommandOutbox
  alias SddOrchestrator.Delivery.CommandTransport.Channel, as: Transport
  alias SddOrchestrator.Delivery.Dispatcher
  alias SddOrchestrator.Delivery.ExecutionManifest
  alias SddOrchestrator.Delivery.WorkerProtocol
  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.DeliveryProtocolFixtures
  alias SddOrchestrator.WorkerDouble
  alias SddOrchestratorWeb.WorkerChannel
  alias SddOrchestratorWeb.WorkerChannelEnvelopeSource, as: EnvelopeSource

  setup do
    on_exit(EnvelopeSource.install())

    context = DeliveryFixtures.delivery_project_fixture()
    feature = DeliveryFixtures.feature_fixture(context.project, context.account)
    run = DeliveryFixtures.run_fixture(context.project, feature)

    %{
      account: context.account,
      project: context.project,
      feature: feature,
      run: run
    }
  end

  describe "authentication" do
    test "a signed credential opens one worker socket", %{project: project} do
      assert {:ok, socket} = WorkerDouble.connect_worker(project.id)
      assert socket.assigns.project_id == project.id
      assert socket.assigns.worker_id == DeliveryProtocolFixtures.worker_id()
    end

    test "a connection without a credential is refused" do
      assert WorkerDouble.connect_with(%{}) == :error
    end

    test "a tampered credential is refused", %{project: project} do
      credential = WorkerDouble.token(project.id) <> "x"

      assert WorkerDouble.connect_with(%{"token" => credential}) == :error
    end

    test "a stale credential is refused", %{project: project} do
      assert WorkerDouble.connect_worker(project.id, token: WorkerDouble.stale_token(project.id)) ==
               :error
    end

    test "a credential naming no valid execution target is refused" do
      assert WorkerDouble.connect_worker("not a project id", worker_id: "worker id") == :error
    end
  end

  describe "channel" do
    test "a worker joins its own project topic", %{project: project} do
      assert {:ok, reply, channel} = WorkerDouble.attach(project.id)

      assert reply.protocol_version == WorkerProtocol.version()
      assert channel.topic == "worker:#{project.id}"
    end

    test "a topic the gateway does not serve is refused", %{project: project} do
      {:ok, socket} = WorkerDouble.connect_worker(project.id)

      assert {:error, %{reason: "unknown_topic"}} =
               WorkerDouble.join_topic(socket, "provisioning:#{project.id}")
    end

    test "a message name the gateway does not implement is refused", %{project: project} do
      {:ok, _reply, channel} = WorkerDouble.attach(project.id)

      ref = WorkerDouble.unsupported(channel)

      assert_reply ref, :error, %{reason: "unsupported_message"}
    end
  end

  describe "cross-workspace denial" do
    test "a credential for one project cannot join another", %{project: project} do
      other = DeliveryFixtures.delivery_project_fixture().project

      assert {:error, %{reason: "unauthorized_execution_target"}} =
               WorkerDouble.attach(project.id, topic_project_id: other.id)
    end

    test "a refused join attaches no worker for either project", %{project: project} do
      other = DeliveryFixtures.delivery_project_fixture().project

      {:error, _reason} = WorkerDouble.attach(project.id, topic_project_id: other.id)

      assert Transport.attached(project.id) == []
      assert Transport.attached(other.id) == []
    end

    test "another project's command cannot be acknowledged", context do
      other = DeliveryFixtures.delivery_project_fixture()
      other_feature = DeliveryFixtures.feature_fixture(other.project, other.account)
      other_run = DeliveryFixtures.run_fixture(other.project, other_feature)

      {foreign, _envelope} =
        enqueue_start(%{project: other.project, feature: other_feature, run: other_run})

      {:ok, _reply, channel} = WorkerDouble.attach(context.project.id)

      ref =
        WorkerDouble.acknowledge(channel, %{
          "command_id" => foreign.id,
          "run_id" => other_run.id
        })

      assert_reply ref, :error, %{reason: "unknown_command"}
      assert {:ok, unchanged} = CommandOutbox.fetch(foreign.id)
      assert unchanged.state == "pending"
    end

    test "a heartbeat for another execution target is refused", %{project: project, run: run} do
      {:ok, _reply, channel} = WorkerDouble.attach(project.id)

      ref =
        WorkerDouble.heartbeat(channel, %{
          "run_id" => run.id,
          "worker_id" => "wrk_someone_else"
        })

      assert_reply ref, :error, %{reason: "unauthorized_execution_target"}
    end
  end

  describe "capability negotiation" do
    test "the granted contract is returned on join", %{project: project} do
      {:ok, reply, _channel} = WorkerDouble.attach(project.id)

      assert reply.protocol_version == WorkerProtocol.version()
      assert reply.capabilities == WorkerProtocol.capabilities()
    end

    test "an unknown capability is ignored rather than granted", %{project: project} do
      announcement = %{"capabilities" => WorkerProtocol.capabilities() ++ ["run.anything"]}

      {:ok, reply, _channel} = WorkerDouble.attach(project.id, announcement: announcement)

      refute "run.anything" in reply.capabilities
    end

    test "a worker missing a required capability is refused", %{project: project} do
      announcement = %{
        "capabilities" => Enum.reject(WorkerProtocol.capabilities(), &(&1 == "run.start"))
      }

      assert {:error, %{reason: "missing_required_capability"}} =
               WorkerDouble.attach(project.id, announcement: announcement)
    end

    test "an incompatible protocol version is refused before any command is delivered",
         context do
      {command, envelope} = enqueue_start(context)
      EnvelopeSource.script(command.id, envelope)

      assert {:error, %{reason: "unsupported_protocol_version"}} =
               WorkerDouble.attach(context.project.id, announcement: %{"protocol_version" => 99})

      assert Transport.deliver(command) == {:error, :no_worker}
    end
  end

  describe "command delivery" do
    test "a claimed command reaches the attached worker", context do
      {command, envelope} = enqueue_start(context)
      EnvelopeSource.script(command.id, envelope)
      {:ok, _reply, _channel} = WorkerDouble.attach(context.project.id)

      assert Transport.deliver(command) == :ok
      assert_push "command", ^envelope
    end

    test "a control command carries no manifest of its own", context do
      {command, envelope} = enqueue_cancel(context)
      EnvelopeSource.script(command.id, envelope)
      {:ok, _reply, _channel} = WorkerDouble.attach(context.project.id)

      assert command.manifest_digest == nil
      assert Transport.deliver(command) == :ok
      assert_push "command", ^envelope
    end

    test "the dispatcher records a delivery through the gateway", context do
      {command, envelope} = enqueue_start(context)
      EnvelopeSource.script(command.id, envelope)
      {:ok, _reply, _channel} = WorkerDouble.attach(context.project.id)

      original = Application.get_env(:sdd_orchestrator, :command_transport)
      Application.put_env(:sdd_orchestrator, :command_transport, Transport)
      on_exit(fn -> Application.put_env(:sdd_orchestrator, :command_transport, original) end)

      assert %{delivered: 1} = Dispatcher.dispatch_now()
      assert_push "command", ^envelope
      assert {:ok, delivered} = CommandOutbox.fetch(command.id)
      assert delivered.state == "delivered"
      assert delivered.delivery_count == 1
    end

    test "no attached worker leaves the command queued", context do
      {command, envelope} = enqueue_start(context)
      EnvelopeSource.script(command.id, envelope)

      assert Transport.deliver(command) == {:error, :no_worker}
    end

    test "an attached worker on an unsupported contract is incompatible", context do
      {command, envelope} = enqueue_start(context)
      EnvelopeSource.script(command.id, envelope)

      attach_stand_in(context.project.id, %{
        worker_id: "wrk_superseded",
        protocol_version: 0,
        capabilities: WorkerProtocol.capabilities()
      })

      assert Transport.deliver(command) == {:error, :incompatible_worker}
      refute_push "command", %{}
    end

    test "an attached worker without the operation's capability is incompatible", context do
      {command, envelope} = enqueue_start(context)
      EnvelopeSource.script(command.id, envelope)

      attach_stand_in(context.project.id, %{
        worker_id: "wrk_partial",
        protocol_version: WorkerProtocol.version(),
        capabilities: Enum.reject(WorkerProtocol.capabilities(), &(&1 == "run.start"))
      })

      assert Transport.deliver(command) == {:error, :incompatible_worker}
    end

    test "an envelope that does not bind to the durable command is never pushed", context do
      {command, envelope} = enqueue_start(context)
      EnvelopeSource.script(command.id, Map.put(envelope, "operation", "cancel"))
      {:ok, _reply, _channel} = WorkerDouble.attach(context.project.id)

      assert Transport.deliver(command) == {:error, :transport_error}
      refute_push "command", %{}
    end

    test "delivery fails closed while no envelope source is installed", context do
      {command, _envelope} = enqueue_start(context)
      Application.delete_env(:sdd_orchestrator, :command_envelope_source)
      {:ok, _reply, _channel} = WorkerDouble.attach(context.project.id)

      assert Transport.deliver(command) == {:error, :transport_error}
      refute_push "command", %{}
    end
  end

  describe "acknowledgement" do
    test "the worker's answer is recorded in the durable outbox", context do
      {command, _envelope} = enqueue_start(context)
      {:ok, _reply, channel} = WorkerDouble.attach(context.project.id)

      ref = acknowledge(channel, context, command)

      assert_reply ref, :ok, %{status: "acknowledged"}
      assert {:ok, recorded} = CommandOutbox.fetch(command.id)
      assert recorded.state == "acknowledged"
      assert recorded.result["status"] == "accepted"
    end

    test "a stale acknowledgement is absorbed without replacing the recorded one", context do
      {command, _envelope} = enqueue_start(context)
      {:ok, _reply, channel} = WorkerDouble.attach(context.project.id)

      first = acknowledge(channel, context, command)
      assert_reply first, :ok, %{status: "acknowledged"}

      stale =
        acknowledge(channel, context, command, %{"status" => "rejected", "reason" => "late"})

      assert_reply stale, :ok, %{status: "acknowledged"}

      assert {:ok, recorded} = CommandOutbox.fetch(command.id)
      assert recorded.result["status"] == "accepted"
      assert recorded.result["reason"] == nil
    end

    test "a malformed acknowledgement changes nothing", context do
      {command, _envelope} = enqueue_start(context)
      {:ok, _reply, channel} = WorkerDouble.attach(context.project.id)

      ref =
        WorkerDouble.acknowledge(channel, %{
          "command_id" => command.id,
          "run_id" => context.run.id,
          "status" => "invented"
        })

      assert_reply ref, :error, %{reason: "unsupported_value"}
      assert {:ok, untouched} = CommandOutbox.fetch(command.id)
      assert untouched.state == "pending"
    end

    test "an acknowledgement for an unrecorded command is refused", context do
      {:ok, _reply, channel} = WorkerDouble.attach(context.project.id)

      ref =
        WorkerDouble.acknowledge(channel, %{
          "command_id" => Ecto.UUID.generate(),
          "run_id" => context.run.id
        })

      assert_reply ref, :error, %{reason: "unknown_command"}
    end

    test "an envelope of the wrong type on the acknowledge message is refused", context do
      {:ok, _reply, channel} = WorkerDouble.attach(context.project.id)

      ref = push(channel, "acknowledge", DeliveryProtocolFixtures.heartbeat())

      assert_reply ref, :error, %{reason: "unexpected_envelope"}
    end
  end

  describe "heartbeat" do
    test "liveness is recorded and published", %{project: project, run: run} do
      PubSub.subscribe(SddOrchestrator.PubSub, WorkerChannel.topic(project.id))
      {:ok, _reply, channel} = WorkerDouble.attach(project.id)

      ref = WorkerDouble.heartbeat(channel, %{"run_id" => run.id, "last_sequence" => 7})

      assert_reply ref, :ok, %{status: "recorded"}
      assert_receive {:worker_heartbeat, %{"last_sequence" => 7, "state" => "running"}}
    end

    test "a malformed heartbeat is refused", %{project: project, run: run} do
      PubSub.subscribe(SddOrchestrator.PubSub, WorkerChannel.topic(project.id))
      {:ok, _reply, channel} = WorkerDouble.attach(project.id)

      ref = WorkerDouble.heartbeat(channel, %{"run_id" => run.id, "state" => "napping"})

      assert_reply ref, :error, %{reason: "unsupported_value"}
      refute_receive {:worker_heartbeat, _envelope}
    end
  end

  describe "normalized intake" do
    test "a validated event is published for the tasks that own it", context do
      {command, _envelope} = enqueue_start(context)
      PubSub.subscribe(SddOrchestrator.PubSub, WorkerChannel.topic(context.project.id))
      {:ok, _reply, channel} = WorkerDouble.attach(context.project.id)

      ref =
        WorkerDouble.emit_event(channel, %{
          "run_id" => context.run.id,
          "command_id" => command.id
        })

      assert_reply ref, :ok, %{status: "accepted"}
      assert_receive {:worker_event, %{"event_type" => "progress"}}
    end

    test "a malformed event is refused and never published", context do
      PubSub.subscribe(SddOrchestrator.PubSub, WorkerChannel.topic(context.project.id))
      {:ok, _reply, channel} = WorkerDouble.attach(context.project.id)

      ref = WorkerDouble.malformed_event(channel)

      assert_reply ref, :error, %{reason: "missing_field"}
      refute_receive {:worker_event, _envelope}
    end

    test "an oversized event is refused and never published", context do
      PubSub.subscribe(SddOrchestrator.PubSub, WorkerChannel.topic(context.project.id))
      {:ok, _reply, channel} = WorkerDouble.attach(context.project.id)

      ref = WorkerDouble.oversized_event(channel, %{"run_id" => context.run.id})

      assert_reply ref, :error, %{reason: "payload_too_large"}
      refute_receive {:worker_event, _envelope}
    end

    test "a reconciliation snapshot is accepted and published", context do
      {command, _envelope} = enqueue_start(context)
      PubSub.subscribe(SddOrchestrator.PubSub, WorkerChannel.topic(context.project.id))
      {:ok, _reply, channel} = WorkerDouble.attach(context.project.id)

      ref =
        WorkerDouble.reconcile(channel, %{
          "attempts" => [
            %{
              "run_id" => context.run.id,
              "attempt_number" => 1,
              "command_id" => command.id,
              "fence_token" => 1,
              "last_sequence" => 4,
              "branch" => context.run.branch,
              "state" => "running"
            }
          ]
        })

      assert_reply ref, :ok, %{status: "accepted"}
      assert_receive {:worker_reconciliation, %{"attempts" => [%{"state" => "running"}]}}
    end

    test "a snapshot reporting another execution target is refused", context do
      PubSub.subscribe(SddOrchestrator.PubSub, WorkerChannel.topic(context.project.id))
      {:ok, _reply, channel} = WorkerDouble.attach(context.project.id)

      ref = WorkerDouble.reconcile(channel, %{"worker_id" => "wrk_someone_else"})

      assert_reply ref, :error, %{reason: "unauthorized_execution_target"}
      refute_receive {:worker_reconciliation, _envelope}
    end
  end

  describe "reconnect" do
    test "a departed worker leaves the command queued and delivers again on return",
         context do
      {command, envelope} = enqueue_start(context)
      EnvelopeSource.script(command.id, envelope)

      {:ok, _reply, channel} = WorkerDouble.attach(context.project.id)
      assert Transport.deliver(command) == :ok
      assert_push "command", ^envelope

      disconnect(channel)
      assert detached?(context.project.id)
      assert Transport.deliver(command) == {:error, :no_worker}

      {:ok, _rejoined, _channel} = WorkerDouble.attach(context.project.id)
      assert Transport.deliver(command) == :ok
      assert_push "command", ^envelope
    end

    test "a reconnect that overlaps its predecessor still receives the command", context do
      {command, envelope} = enqueue_start(context)
      EnvelopeSource.script(command.id, envelope)

      {:ok, _first, _channel} = WorkerDouble.attach(context.project.id)
      {:ok, _second, _rejoined} = WorkerDouble.attach(context.project.id)

      assert length(Transport.attached(context.project.id)) == 2
      assert Transport.deliver(command) == :ok
      assert_push "command", ^envelope
    end
  end

  defp acknowledge(channel, context, command, overrides \\ %{}) do
    WorkerDouble.acknowledge(
      channel,
      Map.merge(%{"command_id" => command.id, "run_id" => context.run.id}, overrides)
    )
  end

  defp enqueue_start(%{project: project, feature: feature, run: run}) do
    manifest =
      DeliveryProtocolFixtures.manifest(%{
        "project_id" => project.id,
        "feature_id" => feature.id,
        "run_id" => run.id,
        "attempt_number" => 1
      })

    digest = ExecutionManifest.digest(manifest)
    attempt = DeliveryFixtures.attempt_fixture(run, manifest_digest: digest)

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
        "expected_state_version" => command.expected_state_version,
        "manifest_digest" => digest,
        "payload" => %{"manifest" => ExecutionManifest.to_map(manifest)}
      })

    {command, envelope}
  end

  defp enqueue_cancel(%{project: project, feature: feature, run: run}) do
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

  # A stand-in worker holds a registration the channel would never create, which
  # is how a contract this control plane no longer supports is provable.
  defp attach_stand_in(project_id, contract) do
    test = self()

    worker =
      spawn(fn ->
        {:ok, _registry} = Transport.attach(project_id, contract)
        send(test, {:attached, self()})
        Process.sleep(:infinity)
      end)

    assert_receive {:attached, ^worker}
    on_exit(fn -> Process.exit(worker, :kill) end)

    worker
  end

  # A real worker's connection drops without warning it, so the channel process
  # is closed rather than asked to leave; the test is unlinked first so the drop
  # does not take it down too.
  defp disconnect(channel) do
    Process.unlink(channel.channel_pid)
    close(channel)
  end

  # Registry cleans up after the channel process dies, so the detach is observed
  # rather than assumed.
  defp detached?(project_id) do
    Enum.reduce_while(1..100, false, fn _attempt, _detached ->
      if Transport.attached(project_id) == [] do
        {:halt, true}
      else
        Process.sleep(10)
        {:cont, false}
      end
    end)
  end
end
