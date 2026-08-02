defmodule SddOrchestratorWeb.PersonalAIWorkerChannelTest do
  @moduledoc """
  Proof for the personal AI worker channel (Task 7).

  The properties under test are the ones that decide whether a paired worker
  may carry personal AI traffic at all: a join cannot reach another device
  workspace, the AI capability contract is negotiated before the worker is
  addressable, Slice 07 project-run commands are refused by name, and every
  malformed, oversized, mis-scoped, smuggled, or replayed frame is refused
  whole while the session stays open.
  """
  use SddOrchestrator.DataCase, async: false

  import Phoenix.ChannelTest, except: [join: 2, join: 3, join: 4]

  alias SddOrchestrator.AIRuntime.PersonalWorkerProtocol
  alias SddOrchestrator.AIRuntime.PersonalWorkerRPC
  alias SddOrchestrator.PersonalAIProtocolFixtures
  alias SddOrchestrator.PersonalAIWorkerDouble

  setup do
    %{paired: PersonalAIWorkerDouble.pair_worker()}
  end

  describe "join" do
    test "a paired worker joins its own workspace topic with the negotiated contract",
         %{paired: paired} do
      assert {:ok, contract, channel} = PersonalAIWorkerDouble.attach(paired)

      assert contract.protocol_version == PersonalWorkerProtocol.version()
      assert contract.capabilities == PersonalWorkerProtocol.capabilities()
      assert channel.topic == "personal_ai:#{paired.device_workspace_id}"
    end

    test "a worker cannot join another workspace's topic", %{paired: paired} do
      assert {:error, %{reason: "cross_workspace"}} =
               PersonalAIWorkerDouble.attach(paired, workspace_id: Ecto.UUID.generate())
    end

    test "a worker cannot join another paired worker's workspace", %{paired: paired} do
      other = PersonalAIWorkerDouble.pair_worker()

      assert {:error, %{reason: "cross_workspace"}} =
               PersonalAIWorkerDouble.attach(paired, workspace_id: other.device_workspace_id)
    end

    test "a topic outside the personal AI namespace is refused", %{paired: paired} do
      {:ok, socket} = PersonalAIWorkerDouble.connect_worker(paired.credential)

      assert {:error, %{reason: "unknown_topic"}} =
               PersonalAIWorkerDouble.join_topic(socket, "worker:#{paired.device_workspace_id}")
    end

    test "a topic naming no valid workspace is refused", %{paired: paired} do
      {:ok, socket} = PersonalAIWorkerDouble.connect_worker(paired.credential)

      assert {:error, %{reason: "unknown_topic"}} =
               PersonalAIWorkerDouble.join_workspace(socket, "not-a-workspace")
    end
  end

  describe "capability negotiation" do
    test "the granted contract is the intersection with the server allowlist",
         %{paired: paired} do
      announcement = %{"capabilities" => ["quota/1", "catalog/1", "run.start", "invented/1"]}

      assert {:ok, contract, _channel} =
               PersonalAIWorkerDouble.attach(paired, announcement: announcement)

      assert contract.capabilities == ["catalog/1", "quota/1"]
    end

    test "an unknown protocol version is refused", %{paired: paired} do
      announcement = %{"protocol_version" => "personal-ai/99"}

      assert {:error, %{reason: "unsupported_protocol_version"}} =
               PersonalAIWorkerDouble.attach(paired, announcement: announcement)
    end

    test "an announcement sharing no capability is refused", %{paired: paired} do
      announcement = %{"capabilities" => ["invented/1", "run.start"]}

      assert {:error, %{reason: "no_shared_capability"}} =
               PersonalAIWorkerDouble.attach(paired, announcement: announcement)
    end

    test "a malformed announcement is refused", %{paired: paired} do
      assert {:error, %{reason: "invalid_announcement"}} =
               PersonalAIWorkerDouble.attach(paired, announcement: %{"capabilities" => "all"})
    end
  end

  describe "project-run command exclusion" do
    test "every Slice 07 message name is refused and the session stays open",
         %{paired: paired} do
      {:ok, _contract, channel} = PersonalAIWorkerDouble.attach(paired)

      for name <- PersonalWorkerProtocol.project_run_commands() do
        ref = PersonalAIWorkerDouble.project_run_command(channel, name)

        assert_reply ref, :error, %{reason: "project_run_command_refused"}
        assert Process.alive?(channel.channel_pid)
      end

      # The session still answers after every refusal.
      ref = PersonalAIWorkerDouble.unsupported(channel)
      assert_reply ref, :error, %{reason: "unsupported_message"}
      assert Process.alive?(channel.channel_pid)
    end

    test "a message name the transport does not implement is refused", %{paired: paired} do
      {:ok, _contract, channel} = PersonalAIWorkerDouble.attach(paired)

      ref = PersonalAIWorkerDouble.unsupported(channel)

      assert_reply ref, :error, %{reason: "unsupported_message"}
    end
  end

  describe "response refusal" do
    setup %{paired: paired} do
      {:ok, _contract, channel} = PersonalAIWorkerDouble.attach(paired)
      %{channel: channel}
    end

    test "a response missing a required field changes nothing", %{channel: channel} do
      ref = PersonalAIWorkerDouble.malformed_response(channel)

      assert_reply ref, :error, %{reason: "missing_field"}
      assert Process.alive?(channel.channel_pid)
    end

    test "a response smuggling any extra field past the allowlist is refused",
         %{channel: channel} do
      for field <- ~w(api_key credential provider_email error_text project_content) do
        ref = PersonalAIWorkerDouble.smuggled_response(channel, field)

        assert_reply ref, :error, %{reason: "unknown_field"}
      end
    end

    test "an oversized response is refused", %{channel: channel} do
      ref = PersonalAIWorkerDouble.oversized_response(channel)

      assert_reply ref, :error, %{reason: "payload_too_large"}
    end

    test "a response for an unknown request is refused as a replay", %{channel: channel} do
      ref = PersonalAIWorkerDouble.respond(channel, %{"request_id" => Ecto.UUID.generate()})

      assert_reply ref, :error, %{reason: "replayed_response"}
    end

    test "a response for a completed request is refused and reaches no caller",
         %{paired: paired, channel: channel} do
      {caller_ref, _envelope} = send_request(channel, paired)
      assert_push "ai_request", pushed

      first = PersonalAIWorkerDouble.respond_to(channel, pushed, %{"answer" => 1})
      assert_reply first, :ok, %{status: "completed"}
      assert_receive {PersonalWorkerRPC, ^caller_ref, {:ok, %{"answer" => 1}}}

      replay = PersonalAIWorkerDouble.respond_to(channel, pushed, %{"answer" => 2})
      assert_reply replay, :error, %{reason: "replayed_response"}
      refute_receive {PersonalWorkerRPC, ^caller_ref, _second}
    end
  end

  describe "request admission" do
    setup %{paired: paired} do
      {:ok, _contract, channel} = PersonalAIWorkerDouble.attach(paired)
      %{channel: channel}
    end

    test "an envelope naming another workspace never reaches the worker",
         %{channel: channel} do
      {ref, _envelope} =
        send_request(channel, %{device_workspace_id: Ecto.UUID.generate()})

      assert_receive {PersonalWorkerRPC, ^ref, {:error, :cross_workspace}}
      refute_push "ai_request", %{}
    end

    test "an envelope smuggling any extra field never reaches the worker",
         %{paired: paired, channel: channel} do
      {ref, _envelope} = send_request(channel, paired, %{"access_token" => "leaked"})

      assert_receive {PersonalWorkerRPC, ^ref, {:error, :unknown_field}}
      refute_push "ai_request", %{}
    end

    test "a capability the connection did not negotiate is refused" do
      narrow = PersonalAIWorkerDouble.pair_worker()

      {:ok, _contract, channel} =
        PersonalAIWorkerDouble.attach(narrow, announcement: %{"capabilities" => ["catalog/1"]})

      {ref, _envelope} = send_request(channel, narrow, %{"capability" => "quota/1"})

      assert_receive {PersonalWorkerRPC, ^ref, {:error, :unsupported_capability}}
      refute_push "ai_request", %{}
    end
  end

  # Addresses the channel exactly as the RPC boundary does, so the channel's
  # own double-checks are provable without going through the RPC.
  defp send_request(channel, paired, overrides \\ %{}) do
    ref = make_ref()

    envelope =
      PersonalAIProtocolFixtures.request(
        Map.merge(
          %{
            "request_id" => Ecto.UUID.generate(),
            "device_workspace_id" => paired.device_workspace_id
          },
          Map.new(overrides)
        )
      )

    deadline = System.monotonic_time(:millisecond) + 5_000
    send(channel.channel_pid, {:ai_request, envelope, self(), ref, deadline})

    {ref, envelope}
  end
end
