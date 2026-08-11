defmodule SddOrchestrator.Delivery.InitializationDispatchTest do
  @moduledoc """
  Task 1 proof: capability-grant negotiation, capability-grant denial of an
  out-of-grant operation, and the dispatch round trip to a configured
  `AgentAdapter`.
  """
  use ExUnit.Case, async: false

  alias SddOrchestrator.AgentAdapterDouble, as: Double
  alias SddOrchestrator.Delivery.InitializationDispatch
  alias SddOrchestrator.InitializationDispatchFixtures, as: Fixtures

  describe "negotiate/1" do
    test "grants the intersection of announced and supported capability grants" do
      assert {:ok, %{capability_grants: granted}} =
               InitializationDispatch.negotiate(%{
                 "capability_grants" => ["plan_discovery", "staging_write", "unknown_grant"]
               })

      assert granted == ["plan_discovery", "staging_write"]
    end

    test "refuses an empty intersection" do
      assert {:error, :no_shared_capability_grant} =
               InitializationDispatch.negotiate(%{"capability_grants" => ["unknown_grant"]})
    end

    test "refuses a malformed announcement" do
      assert {:error, :invalid_announcement} = InitializationDispatch.negotiate(%{})
      assert {:error, :invalid_announcement} = InitializationDispatch.negotiate("not-a-map")
    end
  end

  describe "authorize_grant/2" do
    test "accepts a grant that was negotiated" do
      assert :ok = InitializationDispatch.authorize_grant(["plan_discovery"], "plan_discovery")
    end

    test "denies a grant outside the negotiated set" do
      assert {:error, :capability_grant_denied} =
               InitializationDispatch.authorize_grant(["plan_discovery"], "staging_write")

      assert {:error, :capability_grant_denied} =
               InitializationDispatch.authorize_grant(["staging_write"], "plan_discovery")
    end
  end

  describe "dispatch/2" do
    setup do
      restore = Double.install()
      on_exit(restore)
      :ok
    end

    test "routes a validated manifest to the configured agent and returns a typed response" do
      negotiated = ["plan_discovery"]

      assert {:ok, result} =
               InitializationDispatch.dispatch(Fixtures.manifest_attrs(), negotiated)

      assert result.manifest.dispatch_id == Fixtures.dispatch_id()
      assert result.agent_version == "1.4.0"
      assert result.thread_start == :new
      assert %{reference: _reference, thread_ref: _thread_ref, resumed?: false} = result.handle

      assert [%{agent_input: agent_input}] = Double.requests()
      assert agent_input["device_workspace_id"] == Fixtures.device_workspace_id()
      assert agent_input["capability_grant"] == "plan_discovery"
      refute Map.has_key?(agent_input, "working_directory")
    end

    test "denies dispatch when the manifest's grant was not negotiated" do
      negotiated = ["plan_discovery"]
      attrs = Fixtures.manifest_attrs(%{"capability_grant" => "staging_write"})

      assert {:error, :capability_grant_denied} =
               InitializationDispatch.dispatch(attrs, negotiated)

      assert Double.requests() == []
    end

    test "refuses an invalid manifest before ever reaching the agent" do
      attrs = Fixtures.manifest_attrs(%{"capability_grant" => "not_a_real_grant"})

      assert {:error, :invalid_capability_grant} =
               InitializationDispatch.dispatch(attrs, ["plan_discovery"])

      assert Double.requests() == []
    end

    test "surfaces an unavailable agent as a typed refusal" do
      Double.script(%{start: :unavailable})

      assert {:error, :agent_unavailable} =
               InitializationDispatch.dispatch(Fixtures.manifest_attrs(), ["plan_discovery"])
    end

    test "surfaces an agent launch failure as a typed refusal" do
      Double.script(%{start: :fail})

      assert {:error, :agent_launch_failed} =
               InitializationDispatch.dispatch(Fixtures.manifest_attrs(), ["plan_discovery"])
    end
  end

  test "dispatch fails closed with no agent adapter configured" do
    Application.delete_env(:sdd_orchestrator, :agent_adapter)

    assert {:error, :agent_unavailable} =
             InitializationDispatch.dispatch(Fixtures.manifest_attrs(), ["plan_discovery"])
  end
end
