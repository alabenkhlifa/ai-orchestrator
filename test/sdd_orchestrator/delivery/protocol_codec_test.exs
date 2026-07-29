defmodule SddOrchestrator.Delivery.ProtocolCodecTest do
  use ExUnit.Case, async: true

  alias SddOrchestrator.Delivery.{ExecutionManifest, ProtocolCodec, WorkerProtocol}
  alias SddOrchestrator.DeliveryProtocolFixtures, as: Fixtures

  @fixtures Path.expand("../../fixtures/delivery", __DIR__)

  describe "deterministic encoding" do
    test "encodes each envelope to its exact byte-stable fixture" do
      pairs = [
        {Fixtures.command(), "start_command_v1.json"},
        {Fixtures.event(), "progress_event_v1.json"},
        {Fixtures.acknowledgement(), "acknowledgement_v1.json"},
        {Fixtures.heartbeat(), "heartbeat_v1.json"},
        {Fixtures.reconciliation_snapshot(), "reconciliation_snapshot_v1.json"}
      ]

      for {envelope, fixture} <- pairs do
        assert {:ok, encoded} = ProtocolCodec.encode(envelope)
        assert encoded == read_fixture(fixture)
      end
    end

    test "produces identical bytes regardless of map ordering" do
      envelope = Fixtures.command()
      reordered = envelope |> Enum.reverse() |> Map.new()

      assert ProtocolCodec.encode(envelope) == ProtocolCodec.encode(reordered)
    end

    test "round trips every envelope type" do
      envelopes = [
        Fixtures.command(),
        Fixtures.cancel_command(),
        Fixtures.command(%{"operation" => "reconcile", "payload" => %{}}),
        Fixtures.event(),
        Fixtures.acknowledgement(),
        Fixtures.heartbeat(),
        Fixtures.reconciliation_snapshot()
      ]

      for envelope <- envelopes do
        assert {:ok, encoded} = ProtocolCodec.encode(envelope)
        assert {:ok, decoded} = ProtocolCodec.decode(encoded)
        assert decoded == envelope
      end
    end

    test "returns the manifest bound to a command envelope" do
      command = Fixtures.command()

      assert {:ok, manifest} = ProtocolCodec.manifest(command)
      assert ExecutionManifest.digest(manifest) == command["manifest_digest"]
      assert {:error, :manifest_absent} = ProtocolCodec.manifest(Fixtures.cancel_command())
      assert {:error, :manifest_absent} = ProtocolCodec.manifest(Fixtures.heartbeat())
    end
  end

  describe "version and type" do
    test "rejects an unknown protocol version on encode and decode" do
      assert {:error, :unsupported_protocol_version} =
               ProtocolCodec.encode(Fixtures.command(%{"protocol_version" => 2}))

      encoded =
        Fixtures.event()
        |> Map.put("protocol_version", 1)
        |> ProtocolCodec.encode()
        |> elem(1)
        |> String.replace(~s("protocol_version":1), ~s("protocol_version":99))

      assert {:error, :unsupported_protocol_version} = ProtocolCodec.decode(encoded)
    end

    test "rejects an unknown envelope type" do
      assert {:error, :unsupported_envelope_type} =
               ProtocolCodec.encode(Fixtures.command(%{"type" => "shell"}))
    end
  end

  describe "field validation" do
    test "rejects a missing field in every envelope type" do
      envelopes = [
        Fixtures.command(),
        Fixtures.event(),
        Fixtures.acknowledgement(),
        Fixtures.heartbeat(),
        Fixtures.reconciliation_snapshot()
      ]

      for envelope <- envelopes,
          key <- Map.keys(envelope),
          key not in ~w(type protocol_version) do
        assert ProtocolCodec.encode(Map.delete(envelope, key)) == {:error, :missing_field}
      end

      for envelope <- envelopes, key <- ~w(type protocol_version) do
        assert ProtocolCodec.encode(Map.delete(envelope, key)) == {:error, :invalid_envelope}
      end
    end

    test "rejects an unknown field" do
      assert {:error, :unknown_field} =
               ProtocolCodec.encode(Fixtures.command(%{"workspace_path" => "/tmp/run"}))

      assert {:error, :unknown_field} =
               ProtocolCodec.encode(Fixtures.heartbeat(%{"cpu_load" => 0.4}))
    end

    test "rejects invalid identity, ordering, and timestamp values" do
      cases = [
        {Fixtures.command(%{"command_id" => "cmd 1"}), :invalid_identity},
        {Fixtures.command(%{"run_id" => nil}), :invalid_identity},
        {Fixtures.command(%{"fence_token" => 0}), :invalid_ordering_value},
        {Fixtures.command(%{"expected_state_version" => -1}), :invalid_ordering_value},
        {Fixtures.command(%{"issued_at" => "2026-07-29 09:15:00"}), :invalid_timestamp},
        {Fixtures.command(%{"issued_at" => "2026-07-29T09:15:00+02:00"}), :invalid_timestamp},
        {Fixtures.command(%{"operation" => "deploy"}), :unsupported_value},
        {Fixtures.command(%{"manifest_digest" => "short"}), :invalid_manifest_digest},
        {Fixtures.event(%{"sequence" => 0}), :invalid_ordering_value},
        {Fixtures.event(%{"event_type" => "raw_provider_event"}), :unsupported_value},
        {Fixtures.event(%{"source" => "browser"}), :unsupported_value},
        {Fixtures.acknowledgement(%{"status" => "maybe"}), :unsupported_value},
        {Fixtures.acknowledgement(%{"status" => "rejected", "reason" => nil}), :invalid_text},
        {Fixtures.heartbeat(%{"state" => "thinking"}), :unsupported_value},
        {Fixtures.heartbeat(%{"last_sequence" => -1}), :invalid_ordering_value},
        {Fixtures.heartbeat(%{"worker_id" => "worker one"}), :invalid_identity}
      ]

      for {envelope, expected} <- cases do
        assert ProtocolCodec.encode(envelope) == {:error, expected}
      end
    end

    test "requires the command payload to match its operation" do
      assert {:error, :manifest_payload_required} =
               ProtocolCodec.encode(Fixtures.command(%{"payload" => %{}}))

      assert {:error, :invalid_payload} =
               ProtocolCodec.encode(
                 Fixtures.cancel_command(%{"payload" => %{"note" => "stop", "reason" => "stop"}})
               )

      assert {:error, :invalid_payload} =
               ProtocolCodec.encode(
                 Fixtures.command(%{"operation" => "reconcile", "payload" => %{"reason" => "x"}})
               )

      assert {:error, :invalid_payload} = ProtocolCodec.encode(Fixtures.event(%{"payload" => []}))
    end

    test "rejects a manifest that does not match its command binding or digest" do
      other_run = ExecutionManifest.to_map(Fixtures.manifest(%{"run_id" => "run_other_0000009"}))

      assert {:error, :manifest_binding_mismatch} =
               ProtocolCodec.encode(Fixtures.command(%{"payload" => %{"manifest" => other_run}}))

      assert {:error, :manifest_digest_mismatch} =
               ProtocolCodec.encode(
                 Fixtures.command(%{"manifest_digest" => String.duplicate("0", 64)})
               )

      assert {:error, :missing_manifest_field} =
               ProtocolCodec.encode(
                 Fixtures.command(%{
                   "payload" => %{
                     "manifest" =>
                       Fixtures.manifest() |> ExecutionManifest.to_map() |> Map.delete("run_id")
                   }
                 })
               )
    end

    test "validates reconciliation snapshot attempts" do
      attempt = Fixtures.reconciliation_snapshot()["attempts"] |> hd()

      assert {:error, :invalid_snapshot_attempt} =
               ProtocolCodec.encode(
                 Fixtures.reconciliation_snapshot(%{
                   "attempts" => [Map.delete(attempt, "branch")]
                 })
               )

      assert {:error, :unsupported_value} =
               ProtocolCodec.encode(
                 Fixtures.reconciliation_snapshot(%{
                   "attempts" => [Map.put(attempt, "state", "napping")]
                 })
               )

      assert {:error, :duplicate_snapshot_run} =
               ProtocolCodec.encode(
                 Fixtures.reconciliation_snapshot(%{"attempts" => [attempt, attempt]})
               )

      too_many =
        Enum.map(1..101, fn index -> Map.put(attempt, "run_id", "run_#{index}") end)

      assert {:error, :snapshot_too_large} =
               ProtocolCodec.encode(Fixtures.reconciliation_snapshot(%{"attempts" => too_many}))

      assert {:error, :invalid_snapshot} =
               ProtocolCodec.encode(Fixtures.reconciliation_snapshot(%{"attempts" => "none"}))
    end
  end

  describe "malformed and oversized input" do
    test "rejects malformed frames on decode" do
      assert {:error, :invalid_json} = ProtocolCodec.decode("not json")
      assert {:error, :invalid_envelope} = ProtocolCodec.decode("[]")
      assert {:error, :invalid_envelope} = ProtocolCodec.decode("{}")
      assert {:error, :invalid_json} = ProtocolCodec.decode(<<0>>)
      assert {:error, :invalid_envelope} = ProtocolCodec.decode(:command)
      assert {:error, :invalid_envelope} = ProtocolCodec.encode("command")
    end

    test "rejects a duplicate object key instead of taking the last value" do
      duplicated =
        ~s({"type":"heartbeat","type":"command","protocol_version":1})

      assert {:error, :duplicate_object_key} = ProtocolCodec.decode(duplicated)
    end

    test "rejects an oversized payload and envelope" do
      oversized_payload = %{"summary" => String.duplicate("p", 64 * 1_024)}

      assert {:error, :payload_too_large} =
               ProtocolCodec.encode(Fixtures.event(%{"payload" => oversized_payload}))

      oversized_envelope =
        ~s({"padding":") <> String.duplicate("x", 256 * 1_024) <> ~s("})

      assert {:error, :envelope_too_large} = ProtocolCodec.decode(oversized_envelope)
    end
  end

  describe "credential boundary" do
    test "rejects raw credential fields in any envelope" do
      assert {:error, :secret_field_rejected} =
               ProtocolCodec.encode(
                 Fixtures.event(%{"payload" => %{"authorization" => "Bearer live-token"}})
               )

      assert {:error, :secret_field_rejected} =
               ProtocolCodec.encode(
                 Fixtures.cancel_command(%{
                   "payload" => %{"reason" => "stop", "Secret" => "value"}
                 })
               )

      assert {:error, :secret_material_rejected} =
               ProtocolCodec.encode(
                 Fixtures.event(%{
                   "payload" => %{"summary" => "-----BEGIN RSA PRIVATE KEY-----"}
                 })
               )
    end

    test "keeps opaque configured references" do
      envelope =
        Fixtures.event(%{
          "payload" => %{"preview_ref" => "preview://configured", "credential_ref" => "vault://a"}
        })

      assert {:ok, encoded} = ProtocolCodec.encode(envelope)
      assert {:ok, ^envelope} = ProtocolCodec.decode(encoded)
    end
  end

  describe "persistence boundary" do
    test "the protocol modules depend on no repository, schema, or migration" do
      sources =
        "lib/sdd_orchestrator/delivery/*.ex"
        |> Path.wildcard()
        |> Enum.map(&File.read!/1)

      assert length(sources) == 6

      for source <- sources do
        refute source =~ "SddOrchestrator.Repo"
        refute source =~ "Ecto.Schema"
        refute source =~ "Ecto.Multi"
        refute source =~ "use Ecto"
      end
    end

    test "every protocol vocabulary value is covered by an envelope contract" do
      assert Enum.sort(WorkerProtocol.envelope_types()) ==
               Enum.sort(~w(acknowledgement command event heartbeat reconciliation_snapshot))

      for operation <- WorkerProtocol.command_operations() do
        envelope = command_for(operation)
        assert {:ok, _encoded} = ProtocolCodec.encode(envelope)
      end

      for event_type <- WorkerProtocol.event_types() do
        assert {:ok, _encoded} =
                 ProtocolCodec.encode(Fixtures.event(%{"event_type" => event_type}))
      end
    end
  end

  defp command_for(operation) when operation in ~w(start resume retry) do
    Fixtures.command(%{"operation" => operation})
  end

  defp command_for("cancel"), do: Fixtures.cancel_command()

  defp command_for("reconcile") do
    Fixtures.command(%{"operation" => "reconcile", "payload" => %{}})
  end

  defp read_fixture(name) do
    @fixtures |> Path.join(name) |> File.read!() |> String.trim_trailing("\n")
  end
end
