defmodule SddOrchestratorWeb.WorkerWorkspaceChannelTest do
  @moduledoc """
  Task 5 proof: a worker attaches for its Mac, and only for its own.

  The properties under test are the ones AC-05 decides. A workspace-scoped
  credential attaches against the device workspace it names; an attachment
  aimed at another one is refused before anything is negotiated or recorded; an
  overlapping reconnect is admitted rather than stranded; and the record lives
  and dies with the channel process, because it is liveness and nothing else.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Phoenix.ChannelTest

  alias SddOrchestrator.Delivery.CommandTransport.Channel, as: Transport
  alias SddOrchestrator.Delivery.WorkerAttachment
  alias SddOrchestrator.Delivery.WorkerProtocol
  alias SddOrchestrator.DeliveryProtocolFixtures
  alias SddOrchestratorWeb.WorkerSocket

  @endpoint SddOrchestratorWeb.Endpoint

  describe "attachment" do
    test "a worker joins the Mac its credential names" do
      workspace = Ecto.UUID.generate()

      assert {:ok, reply, channel} = attach(workspace)

      assert reply.protocol_version == WorkerProtocol.version()
      assert reply.capabilities == WorkerProtocol.capabilities()
      assert channel.topic == "worker_workspace:#{workspace}"
    end

    test "the attachment is recorded against that device workspace" do
      workspace = Ecto.UUID.generate()

      {:ok, _reply, channel} = attach(workspace)

      assert [{pid, contract}] = WorkerAttachment.attached(workspace)
      assert pid == channel.channel_pid
      assert contract.worker_id == DeliveryProtocolFixtures.worker_id()
      assert contract.protocol_version == WorkerProtocol.version()
      assert contract.capabilities == WorkerProtocol.capabilities()
      assert %DateTime{} = contract.attached_at
    end

    test "the attachment names the worker the credential named, not the announcement" do
      workspace = Ecto.UUID.generate()

      {:ok, _reply, _channel} = attach(workspace, worker_id: "wrk_paired_worker")

      assert [{_pid, %{worker_id: "wrk_paired_worker"}}] = WorkerAttachment.attached(workspace)
    end
  end

  describe "cross-workspace denial" do
    test "a join aimed at another Mac is refused" do
      workspace = Ecto.UUID.generate()

      assert {:error, %{reason: "unauthorized_device_workspace"}} =
               attach(workspace, topic_workspace_id: Ecto.UUID.generate())
    end

    test "the refusal happens before the contract is negotiated" do
      workspace = Ecto.UUID.generate()
      other = Ecto.UUID.generate()

      # An announcement this control plane could never grant. The refusal names
      # the authorization failure rather than the negotiation one, which is only
      # possible if the topic was checked first.
      assert {:error, %{reason: "unauthorized_device_workspace"}} =
               attach(workspace,
                 topic_workspace_id: other,
                 announcement: %{"protocol_version" => 99, "capabilities" => []}
               )
    end

    test "a refused join records nothing for either Mac" do
      workspace = Ecto.UUID.generate()
      other = Ecto.UUID.generate()

      {:error, _refused} = attach(workspace, topic_workspace_id: other)

      assert WorkerAttachment.attached(workspace) == []
      assert WorkerAttachment.attached(other) == []
    end
  end

  describe "overlap and departure" do
    test "a reconnect overlapping its predecessor is admitted rather than refused" do
      workspace = Ecto.UUID.generate()

      {:ok, _first, first_channel} = attach(workspace)
      assert {:ok, _second, second_channel} = attach(workspace)

      attached = WorkerAttachment.attached(workspace)
      pids = Enum.map(attached, fn {pid, _contract} -> pid end)

      assert length(attached) == 2
      assert first_channel.channel_pid in pids
      assert second_channel.channel_pid in pids
    end

    test "the record disappears when the channel process dies" do
      workspace = Ecto.UUID.generate()

      {:ok, _reply, channel} = attach(workspace)
      assert [{_pid, _contract}] = WorkerAttachment.attached(workspace)

      disconnect(channel)

      assert detached?(workspace)
    end
  end

  describe "scope separation" do
    test "a workspace-scoped socket attaches for no project" do
      workspace = Ecto.UUID.generate()
      project_id = Ecto.UUID.generate()
      token = WorkerSocket.issue({:device_workspace, workspace}, "wrk_paired_worker")
      {:ok, socket} = connect(WorkerSocket, %{"token" => token})

      # The project channel reads the project its socket authenticated, and a
      # workspace-scoped socket carries none, so the join dies on the absent
      # assign instead of attaching. The refusal is what matters here: the
      # project topic stays owned by the project-scoped credential, and this
      # slice changes nothing on it.
      log =
        capture_log(fn ->
          assert {:error, %{reason: "join crashed"}} =
                   subscribe_and_join(socket, "worker:#{project_id}", announcement())
        end)

      assert Transport.attached(project_id) == []
      assert WorkerAttachment.attached(workspace) == []
      refute log =~ token
    end

    test "a project-scoped socket cannot attach for a Mac" do
      workspace = Ecto.UUID.generate()
      project_id = Ecto.UUID.generate()
      token = WorkerSocket.issue(project_id, DeliveryProtocolFixtures.worker_id())
      {:ok, socket} = connect(WorkerSocket, %{"token" => token})

      assert {:error, %{reason: "unauthorized_device_workspace"}} =
               subscribe_and_join(socket, "worker_workspace:#{workspace}", announcement())

      assert WorkerAttachment.attached(workspace) == []
    end
  end

  describe "message surface" do
    test "a topic this channel does not serve is refused" do
      workspace = Ecto.UUID.generate()
      {:ok, socket} = connect_workspace(workspace)

      assert {:error, %{reason: "unknown_topic"}} =
               subscribe_and_join(
                 socket,
                 SddOrchestratorWeb.WorkerWorkspaceChannel,
                 "provisioning:#{workspace}",
                 announcement()
               )
    end

    test "a message the attachment channel does not implement is refused" do
      workspace = Ecto.UUID.generate()
      {:ok, _reply, channel} = attach(workspace)

      ref = push(channel, "heartbeat", DeliveryProtocolFixtures.heartbeat())

      # Explicit timeout: `assert_reply`'s 100 ms default is generous when this
      # file runs alone and too tight under a loaded full-suite pass, where it
      # failed on an empty mailbox. The refusal itself is what is being proved,
      # not how fast a busy scheduler delivers it.
      assert_reply ref, :error, %{reason: "unsupported_message"}, 2_000
    end

    test "a refused message leaves the attachment in place" do
      workspace = Ecto.UUID.generate()
      {:ok, _reply, channel} = attach(workspace)

      ref = push(channel, "provision", %{"anything" => true})

      # Explicit timeout: `assert_reply`'s 100 ms default is generous when this
      # file runs alone and too tight under a loaded full-suite pass, where it
      # failed on an empty mailbox. The refusal itself is what is being proved,
      # not how fast a busy scheduler delivers it.
      assert_reply ref, :error, %{reason: "unsupported_message"}, 2_000
      assert [{_pid, _contract}] = WorkerAttachment.attached(workspace)
    end
  end

  defp attach(device_workspace_id, opts \\ []) do
    {:ok, socket} = connect_workspace(device_workspace_id, opts)

    subscribe_and_join(
      socket,
      "worker_workspace:#{Keyword.get(opts, :topic_workspace_id, device_workspace_id)}",
      announcement(Keyword.get(opts, :announcement, %{}))
    )
  end

  defp connect_workspace(device_workspace_id, opts \\ []) do
    worker_id = Keyword.get(opts, :worker_id, DeliveryProtocolFixtures.worker_id())
    token = WorkerSocket.issue({:device_workspace, device_workspace_id}, worker_id)

    connect(WorkerSocket, %{"token" => token})
  end

  defp announcement(overrides \\ %{}), do: DeliveryProtocolFixtures.announcement(overrides)

  # A real worker's connection drops without warning it, so the channel process
  # is closed rather than asked to leave; the test is unlinked first so the drop
  # does not take it down too.
  defp disconnect(channel) do
    Process.unlink(channel.channel_pid)
    close(channel)
  end

  # Registry cleans up after the channel process dies, so the detach is observed
  # rather than assumed.
  defp detached?(device_workspace_id) do
    Enum.reduce_while(1..100, false, fn _attempt, _detached ->
      if WorkerAttachment.attached(device_workspace_id) == [] do
        {:halt, true}
      else
        Process.sleep(10)
        {:cont, false}
      end
    end)
  end
end
