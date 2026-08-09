defmodule SddOrchestratorWeb.InitializationWorkerChannelTest do
  @moduledoc """
  Task 1 proof: channel addressing, capability-grant negotiation, denial of
  an out-of-grant dispatch, and the live dispatch round trip to a configured
  `AgentAdapter`.
  """
  use SddOrchestrator.DataCase, async: false

  import Phoenix.ChannelTest

  alias SddOrchestrator.AgentAdapterDouble, as: Double
  alias SddOrchestrator.InitializationDispatchFixtures, as: Fixtures
  alias SddOrchestrator.InitializationWorkerDouble

  setup do
    %{paired: InitializationWorkerDouble.pair_worker()}
  end

  describe "join" do
    test "a paired worker joins its own workspace topic with the negotiated contract",
         %{paired: paired} do
      assert {:ok, contract, channel} = InitializationWorkerDouble.attach(paired)

      assert contract.capability_grants == ["plan_discovery", "staging_write"]
      assert channel.topic == "initialization:#{paired.device_workspace_id}"
    end

    test "a worker cannot join another workspace's topic", %{paired: paired} do
      assert {:error, %{reason: "cross_workspace"}} =
               InitializationWorkerDouble.attach(paired, workspace_id: Ecto.UUID.generate())
    end

    test "a worker cannot join another paired worker's workspace", %{paired: paired} do
      other = InitializationWorkerDouble.pair_worker()

      assert {:error, %{reason: "cross_workspace"}} =
               InitializationWorkerDouble.attach(paired, workspace_id: other.device_workspace_id)
    end

    test "a revoked worker cannot join even with a still-live socket", %{paired: paired} do
      {:ok, socket} = InitializationWorkerDouble.connect_worker(paired.credential)
      {:ok, _revoked} = SddOrchestrator.Devices.Pairing.revoke_worker(paired.worker)

      assert {:error, %{reason: "cross_workspace"}} =
               InitializationWorkerDouble.join_workspace(socket, paired.device_workspace_id)
    end

    test "a topic outside the initialization namespace is refused", %{paired: paired} do
      {:ok, socket} = InitializationWorkerDouble.connect_worker(paired.credential)

      assert {:error, %{reason: "unknown_topic"}} =
               InitializationWorkerDouble.join_topic(
                 socket,
                 "worker:#{paired.device_workspace_id}"
               )
    end

    test "a topic naming no valid workspace is refused", %{paired: paired} do
      {:ok, socket} = InitializationWorkerDouble.connect_worker(paired.credential)

      assert {:error, %{reason: "unknown_topic"}} =
               InitializationWorkerDouble.join_workspace(socket, "not-a-workspace")
    end
  end

  describe "capability-grant negotiation" do
    test "the granted contract is the intersection with the server allowlist",
         %{paired: paired} do
      announcement = %{"capability_grants" => ["plan_discovery", "invented_grant"]}

      assert {:ok, contract, _channel} =
               InitializationWorkerDouble.attach(paired, announcement: announcement)

      assert contract.capability_grants == ["plan_discovery"]
    end

    test "an announcement sharing no capability grant is refused", %{paired: paired} do
      announcement = %{"capability_grants" => ["invented_grant"]}

      assert {:error, %{reason: "no_shared_capability_grant"}} =
               InitializationWorkerDouble.attach(paired, announcement: announcement)
    end

    test "a malformed announcement is refused", %{paired: paired} do
      assert {:error, %{reason: "invalid_announcement"}} =
               InitializationWorkerDouble.attach(paired,
                 announcement: %{"capability_grants" => "all"}
               )
    end
  end

  describe "dispatch" do
    setup do
      restore = Double.install()
      on_exit(restore)
      :ok
    end

    test "a manifest within the negotiated grant dispatches to the configured agent",
         %{paired: paired} do
      {:ok, _contract, channel} =
        InitializationWorkerDouble.attach(paired,
          announcement: %{"capability_grants" => ["plan_discovery"]}
        )

      payload =
        Fixtures.manifest_attrs(%{"device_workspace_id" => paired.device_workspace_id})
        |> Map.delete("device_workspace_id")

      ref = push(channel, "dispatch", payload)

      assert_reply ref, :ok, %{
        dispatch_id: dispatch_id,
        agent_version: "1.4.0",
        thread_start: "new"
      }

      assert dispatch_id == Fixtures.dispatch_id()
    end

    test "a manifest outside the negotiated grant is denied", %{paired: paired} do
      {:ok, _contract, channel} =
        InitializationWorkerDouble.attach(paired,
          announcement: %{"capability_grants" => ["plan_discovery"]}
        )

      payload =
        Fixtures.manifest_attrs(%{"capability_grant" => "staging_write"})
        |> Map.delete("device_workspace_id")

      ref = push(channel, "dispatch", payload)

      assert_reply ref, :error, %{reason: "capability_grant_denied"}
      assert Double.requests() == []
    end

    test "an unsupported message name is refused and the session stays open", %{paired: paired} do
      {:ok, _contract, channel} = InitializationWorkerDouble.attach(paired)

      ref = push(channel, "provision", %{})

      assert_reply ref, :error, %{reason: "unsupported_message"}
    end
  end
end
