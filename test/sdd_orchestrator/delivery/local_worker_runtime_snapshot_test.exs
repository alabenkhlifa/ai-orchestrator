defmodule SddOrchestrator.Delivery.LocalWorkerRuntimeSnapshotTest do
  use ExUnit.Case, async: true

  alias SddOrchestrator.Delivery.{AgentRun, LocalWorkerRuntimeSnapshot, RunAttempt}

  @run %AgentRun{state: "running"}

  describe "snapshot/3" do
    test "computes elapsed_seconds from attempt.inserted_at and the injected now" do
      inserted_at = ~U[2026-08-08 10:00:00Z]
      now = ~U[2026-08-08 10:05:30Z]
      attempt = %RunAttempt{state: "running", inserted_at: inserted_at}

      snapshot = LocalWorkerRuntimeSnapshot.snapshot(@run, attempt, now: now)

      assert snapshot.elapsed_seconds == 330
    end

    test "floors elapsed_seconds at 0 when now is before inserted_at" do
      inserted_at = ~U[2026-08-08 10:00:00Z]
      now = ~U[2026-08-08 09:59:00Z]
      attempt = %RunAttempt{state: "running", inserted_at: inserted_at}

      snapshot = LocalWorkerRuntimeSnapshot.snapshot(@run, attempt, now: now)

      assert snapshot.elapsed_seconds == 0
    end

    test "defaults now to the real current time when not injected" do
      inserted_at = DateTime.add(DateTime.utc_now(), -10, :second)
      attempt = %RunAttempt{state: "running", inserted_at: inserted_at}

      snapshot = LocalWorkerRuntimeSnapshot.snapshot(@run, attempt)

      assert snapshot.elapsed_seconds >= 10
      assert snapshot.elapsed_seconds < 30
    end

    for state <- ["pending", "dispatched", "running", "succeeded", "failed", "canceled"] do
      test "passes attempt.state #{state} through unchanged as status" do
        attempt = %RunAttempt{state: unquote(state), inserted_at: ~U[2026-08-08 10:00:00Z]}

        snapshot =
          LocalWorkerRuntimeSnapshot.snapshot(@run, attempt, now: ~U[2026-08-08 10:00:05Z])

        assert snapshot.status == unquote(state)
      end
    end

    test "tokens and cost are always :unknown regardless of input" do
      attempt = %RunAttempt{state: "succeeded", inserted_at: ~U[2026-08-08 10:00:00Z]}

      snapshot =
        LocalWorkerRuntimeSnapshot.snapshot(@run, attempt, now: ~U[2026-08-08 12:00:00Z])

      assert snapshot.tokens == :unknown
      assert snapshot.cost == :unknown
    end

    test "returns exactly the four documented keys" do
      attempt = %RunAttempt{state: "running", inserted_at: ~U[2026-08-08 10:00:00Z]}

      snapshot =
        LocalWorkerRuntimeSnapshot.snapshot(@run, attempt, now: ~U[2026-08-08 10:00:05Z])

      assert Map.keys(snapshot) |> Enum.sort() == [:cost, :elapsed_seconds, :status, :tokens]
    end
  end
end
