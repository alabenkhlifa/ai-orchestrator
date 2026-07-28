defmodule SddOrchestrator.Devices.WorkerDiscoveryTest do
  @moduledoc """
  Task 2 proof (policy): the worker discovery classification covers the detected,
  missing, incompatible, and unavailable states from the supported macOS/protocol
  compatibility policy and `last_seen_at` reachability, independent of the store.
  """
  use ExUnit.Case, async: true

  alias SddOrchestrator.Devices.LocalWorker
  alias SddOrchestrator.Devices.WorkerDiscovery

  @now ~U[2026-07-27 12:00:00Z]

  defp worker(attrs) do
    struct(
      %LocalWorker{
        os_family: "macos",
        os_major: "15",
        protocol_version: "1",
        state: "active",
        last_seen_at: @now
      },
      attrs
    )
  end

  describe "status/2" do
    test "is :missing when no worker is paired" do
      assert WorkerDiscovery.status([], now: @now) == :missing
    end

    test "is :detected for a compatible worker seen recently" do
      assert WorkerDiscovery.status([worker(%{})], now: @now) == :detected
    end

    test "accepts both supported macOS majors" do
      assert WorkerDiscovery.status([worker(%{os_major: "14"})], now: @now) == :detected
      assert WorkerDiscovery.status([worker(%{os_major: "15"})], now: @now) == :detected
    end

    test "is :incompatible for an unsupported operating-system family" do
      assert WorkerDiscovery.status([worker(%{os_family: "windows"})], now: @now) == :incompatible
      assert WorkerDiscovery.status([worker(%{os_family: "linux"})], now: @now) == :incompatible
    end

    test "is :incompatible for an unsupported macOS major" do
      assert WorkerDiscovery.status([worker(%{os_major: "13"})], now: @now) == :incompatible
      assert WorkerDiscovery.status([worker(%{os_major: "16"})], now: @now) == :incompatible
    end

    test "is :incompatible for an unsupported protocol version" do
      assert WorkerDiscovery.status([worker(%{protocol_version: "2"})], now: @now) ==
               :incompatible

      assert WorkerDiscovery.status([worker(%{protocol_version: nil})], now: @now) ==
               :incompatible
    end

    test "is :unavailable for a compatible worker that has never reported" do
      assert WorkerDiscovery.status([worker(%{last_seen_at: nil})], now: @now) == :unavailable
    end

    test "is :unavailable for a compatible worker whose heartbeat is stale" do
      stale = DateTime.add(@now, -(WorkerDiscovery.staleness_seconds() + 1), :second)
      assert WorkerDiscovery.status([worker(%{last_seen_at: stale})], now: @now) == :unavailable
    end

    test "treats a worker seen exactly at the staleness boundary as reachable" do
      edge = DateTime.add(@now, -WorkerDiscovery.staleness_seconds(), :second)
      assert WorkerDiscovery.status([worker(%{last_seen_at: edge})], now: @now) == :detected
    end

    test "is :detected when any compatible worker is reachable despite an incompatible one" do
      workers = [worker(%{os_family: "windows"}), worker(%{os_major: "14"})]
      assert WorkerDiscovery.status(workers, now: @now) == :detected
    end

    test "is :unavailable when compatible workers exist but none is reachable" do
      workers = [worker(%{last_seen_at: nil}), worker(%{os_major: "13"})]
      assert WorkerDiscovery.status(workers, now: @now) == :unavailable
    end

    test "prefers :incompatible over :unavailable when no worker is compatible" do
      workers = [worker(%{os_major: "13", last_seen_at: nil})]
      assert WorkerDiscovery.status(workers, now: @now) == :incompatible
    end
  end

  describe "compatible?/1 and policy" do
    test "compatible?/1 matches the published policy" do
      assert WorkerDiscovery.compatible?(worker(%{}))
      refute WorkerDiscovery.compatible?(worker(%{os_family: "windows"}))
      refute WorkerDiscovery.compatible?(worker(%{os_major: "13"}))
      refute WorkerDiscovery.compatible?(worker(%{protocol_version: "9"}))
    end

    test "compatibility_policy/0 reports the supported macOS majors and protocol" do
      policy = WorkerDiscovery.compatibility_policy()
      assert policy.os_family == "macos"
      assert "14" in policy.os_majors and "15" in policy.os_majors
      assert policy.protocol_versions == ["1"]
    end
  end
end
