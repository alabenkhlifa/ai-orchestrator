defmodule SddOrchestrator.Devices.WorkerDiscoveryTest do
  @moduledoc """
  Task 2 proof (policy): the worker discovery classification covers the detected,
  missing, incompatible, and unavailable states from the supported macOS/protocol
  compatibility policy and `last_seen_at` reachability, independent of the store.

  Task 10 proof (computed window): the supported macOS majors are derived from
  the maintained major/GA-release-date table against the evaluated instant, with
  one major of forward tolerance above the highest tabulated entry.
  """
  use ExUnit.Case, async: true

  alias SddOrchestrator.Devices.LocalWorker
  alias SddOrchestrator.Devices.WorkerDiscovery

  @now ~U[2026-07-27 12:00:00Z]

  defp worker(attrs) do
    struct(
      %LocalWorker{
        os_family: "macos",
        os_major: "26",
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
      assert WorkerDiscovery.status([worker(%{os_major: "15"})], now: @now) == :detected
      assert WorkerDiscovery.status([worker(%{os_major: "26"})], now: @now) == :detected
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
      workers = [worker(%{os_family: "windows"}), worker(%{os_major: "15"})]
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
      policy = WorkerDiscovery.compatibility_policy(now: @now)
      assert policy.os_family == "macos"
      assert policy.os_majors == ["15", "26"]
      assert policy.protocol_versions == ["1"]
    end
  end

  describe "computed macOS compatibility window (Task 10)" do
    # {tabulated GA date, window the day before, window on the day of}. These are
    # the same rows `WorkerDiscovery` computes from, asserted at both edges.
    @boundaries [
      {~D[2022-10-24], ["13"], ["13"]},
      {~D[2023-09-26], ["13"], ["13", "14"]},
      {~D[2024-09-16], ["13", "14"], ["14", "15"]},
      {~D[2025-09-15], ["14", "15"], ["15", "26"]}
    ]

    test "the window opens exactly on each tabulated release date, not the day before" do
      for {ga, before_window, on_window} <- @boundaries do
        assert WorkerDiscovery.compatibility_policy(now: Date.add(ga, -1)).os_majors ==
                 before_window,
               "window the day before #{ga} should be #{inspect(before_window)}"

        assert WorkerDiscovery.compatibility_policy(now: ga).os_majors == on_window,
               "window on #{ga} should be #{inspect(on_window)}"
      end
    end

    test "a major below the computed floor stays incompatible" do
      refute WorkerDiscovery.compatible?(worker(%{os_major: "14"}), now: @now)
      refute WorkerDiscovery.compatible?(worker(%{os_major: "13"}), now: @now)

      assert WorkerDiscovery.compatible?(worker(%{os_major: "14"}), now: ~D[2024-09-16])
    end

    test "exactly one major above the highest tabulated entry is tolerated" do
      assert WorkerDiscovery.compatible?(worker(%{os_major: "27"}), now: @now)
      assert WorkerDiscovery.status([worker(%{os_major: "27"})], now: @now) == :detected
    end

    test "two or more majors above the highest tabulated entry stay incompatible" do
      refute WorkerDiscovery.compatible?(worker(%{os_major: "28"}), now: @now)
      refute WorkerDiscovery.compatible?(worker(%{os_major: "30"}), now: @now)
      assert WorkerDiscovery.status([worker(%{os_major: "28"})], now: @now) == :incompatible
    end

    test "a non-numeric or missing major is never tolerated" do
      refute WorkerDiscovery.compatible?(worker(%{os_major: "27beta"}), now: @now)
      refute WorkerDiscovery.compatible?(worker(%{os_major: nil}), now: @now)
    end

    test "the live window against the real clock keeps the two-major shape callers rely on" do
      majors = WorkerDiscovery.compatibility_policy().os_majors

      assert length(majors) == 2
      assert Enum.all?(majors, &is_binary/1)
      assert WorkerDiscovery.compatible?(worker(%{os_major: List.last(majors)}))
    end
  end
end
