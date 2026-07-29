defmodule SddOrchestrator.Delivery.WorkerProtocolTest do
  use ExUnit.Case, async: true

  alias SddOrchestrator.Delivery.WorkerProtocol
  alias SddOrchestrator.DeliveryProtocolFixtures, as: Fixtures

  describe "version" do
    test "declares one current version and accepts only supported versions" do
      assert WorkerProtocol.version() == 1
      assert WorkerProtocol.supported_versions() == [1]
      assert WorkerProtocol.supported_version?(1)

      refute WorkerProtocol.supported_version?(2)
      refute WorkerProtocol.supported_version?(0)
      refute WorkerProtocol.supported_version?("1")
      refute WorkerProtocol.supported_version?(nil)
    end

    test "exposes the fixed envelope, operation, and event vocabulary" do
      assert WorkerProtocol.envelope_types() == [
               "acknowledgement",
               "command",
               "event",
               "heartbeat",
               "reconciliation_snapshot"
             ]

      assert WorkerProtocol.command_operations() == ~w(cancel reconcile resume retry start)
      assert WorkerProtocol.manifest_operations() == ~w(resume retry start)
      assert "progress" in WorkerProtocol.event_types()
      assert "blocked" in WorkerProtocol.event_types()
      assert WorkerProtocol.event_sources() == ~w(agent check worker)
    end
  end

  describe "negotiate/1" do
    test "grants the announced capabilities the protocol knows" do
      assert {:ok, negotiated} = WorkerProtocol.negotiate(Fixtures.announcement())

      assert negotiated.protocol_version == 1
      assert negotiated.capabilities == WorkerProtocol.capabilities()
    end

    test "ignores unknown capability names instead of granting them" do
      announcement =
        Fixtures.announcement(%{
          "capabilities" => WorkerProtocol.capabilities() ++ ["worker.debug_shell"]
        })

      assert {:ok, negotiated} = WorkerProtocol.negotiate(announcement)
      refute "worker.debug_shell" in negotiated.capabilities
      assert negotiated.capabilities == WorkerProtocol.capabilities()
    end

    test "grants a worker that announces only the required capabilities" do
      announcement =
        Fixtures.announcement(%{"capabilities" => WorkerProtocol.required_capabilities()})

      assert {:ok, negotiated} = WorkerProtocol.negotiate(announcement)
      assert negotiated.capabilities == Enum.sort(WorkerProtocol.required_capabilities())

      refute Enum.any?(
               WorkerProtocol.optional_capabilities(),
               &(&1 in negotiated.capabilities)
             )
    end

    test "rejects an incompatible protocol version before dispatch" do
      assert {:error, :unsupported_protocol_version} =
               WorkerProtocol.negotiate(Fixtures.announcement(%{"protocol_version" => 2}))

      assert {:error, :unsupported_protocol_version} =
               WorkerProtocol.negotiate(Fixtures.announcement(%{"protocol_version" => "1"}))
    end

    test "rejects a worker that is missing any required capability" do
      for missing <- WorkerProtocol.required_capabilities() do
        announcement =
          Fixtures.announcement(%{
            "capabilities" => Enum.reject(WorkerProtocol.capabilities(), &(&1 == missing))
          })

        assert {:error, :missing_required_capability} = WorkerProtocol.negotiate(announcement)
      end
    end

    test "rejects a malformed or oversized announcement" do
      assert {:error, :invalid_announcement} = WorkerProtocol.negotiate(%{})

      assert {:error, :invalid_announcement} =
               WorkerProtocol.negotiate(%{"protocol_version" => 1, "capabilities" => "run.start"})

      oversized = Enum.map(1..65, &"capability.#{&1}")

      assert {:error, :too_many_capabilities} =
               WorkerProtocol.negotiate(Fixtures.announcement(%{"capabilities" => oversized}))
    end
  end

  describe "identifiers" do
    test "generates stable url-safe identifiers that satisfy the protocol format" do
      ids = Enum.map(1..50, fn _index -> WorkerProtocol.generate_id() end)

      assert Enum.all?(ids, &WorkerProtocol.valid_id?/1)
      assert length(Enum.uniq(ids)) == 50
    end

    test "rejects empty, oversized, and unsafe identifiers" do
      refute WorkerProtocol.valid_id?("")
      refute WorkerProtocol.valid_id?(String.duplicate("a", 65))
      refute WorkerProtocol.valid_id?("run id")
      refute WorkerProtocol.valid_id?("run/../id")
      refute WorkerProtocol.valid_id?("run\nid")
      refute WorkerProtocol.valid_id?(:run)
      refute WorkerProtocol.valid_id?(nil)
      refute WorkerProtocol.valid_id?(1)

      assert WorkerProtocol.valid_id?(String.duplicate("a", 64))
      assert WorkerProtocol.valid_id?(Ecto.UUID.generate())
    end
  end
end
