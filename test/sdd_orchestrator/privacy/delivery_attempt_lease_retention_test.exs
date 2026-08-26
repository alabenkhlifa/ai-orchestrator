defmodule SddOrchestrator.Privacy.DeliveryAttemptLeaseRetentionTest do
  @moduledoc """
  Task 9 proof: spent attempt-lease claims are released, not deleted.

  A lease names the one worker allowed to execute an attempt and until when.
  Once the attempt is terminal no worker can ever act under that claim again —
  every transition out of a terminal state is illegal — so 30 days later the
  claim is cleared while the attempt row itself stays exactly as it was.

  The two halves of that sentence are what this file proves. `lease_owner` and
  `lease_expires_at` go to null together, because `run_attempts_lease_pairing`
  refuses one without the other and a half-cleared write would abort the whole
  `prune_all/1` pass. And nothing else on the row moves: the attempt, its
  outcome, its ordering, and above all its `fence_token` — the value that keeps
  a superseded worker's late events rejected — are participant-visible history
  owned by the delivery lifecycle and expire with the run, not on this window.
  """

  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Delivery.RunAttempt
  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.Privacy.Retention

  @day 24 * 60 * 60
  @window 30 * @day

  setup do
    context = DeliveryFixtures.delivery_project_fixture()
    feature = DeliveryFixtures.feature_fixture(context.project, context.account)

    %{project: context.project, account: context.account, feature: feature}
  end

  describe "spent attempt-lease release" do
    test "releases the claim of every terminal state at the 30-day boundary", context do
      now = truncated_now()
      due_at = DateTime.add(now, -@window, :second)

      # Driven off `terminal_states/0` rather than a literal list, so a state
      # added to the lifecycle later fails here instead of quietly retaining a
      # claim forever.
      attempts =
        Enum.map(RunAttempt.terminal_states(), fn state ->
          planted_attempt(context, state: state, at: due_at)
        end)

      assert length(attempts) == 4

      assert %{released_delivery_attempt_leases: 4} = Retention.prune_all(now)

      for attempt <- attempts do
        released = Repo.get!(RunAttempt, attempt.id)

        assert released.state == attempt.state
        assert released.lease_owner == nil
        assert released.lease_expires_at == nil
      end
    end

    test "keeps a claim one second inside the window", context do
      now = truncated_now()

      due = planted_attempt(context, at: DateTime.add(now, -@window, :second))
      just_inside = planted_attempt(context, at: DateTime.add(now, -@window + 1, :second))

      assert %{released_delivery_attempt_leases: 1} = Retention.prune_all(now)

      assert Repo.get!(RunAttempt, due.id).lease_owner == nil

      retained = Repo.get!(RunAttempt, just_inside.id)
      assert retained.lease_owner == just_inside.lease_owner
      assert retained.lease_expires_at == just_inside.lease_expires_at
    end

    test "never releases a current attempt's claim, whatever its age", context do
      now = truncated_now()

      # Ten windows old. Age is not what makes a claim spent — reaching a
      # terminal state is — so a still-current attempt is never selected no
      # matter how long it has been running.
      ancient = DateTime.add(now, -10 * @window, :second)

      current =
        Enum.map(RunAttempt.current_states(), fn state ->
          planted_attempt(context, state: state, at: ancient)
        end)

      assert length(current) == 3

      assert %{released_delivery_attempt_leases: 0} = Retention.prune_all(now)

      for attempt <- current do
        retained = Repo.get!(RunAttempt, attempt.id)

        assert retained.lease_owner == attempt.lease_owner
        assert retained.lease_expires_at == attempt.lease_expires_at
      end
    end

    test "clears both lease columns together and moves nothing else on the row", context do
      now = truncated_now()
      before = planted_attempt(context, at: DateTime.add(now, -@window, :second))

      assert before.lease_owner != nil
      assert before.lease_expires_at != nil

      assert %{released_delivery_attempt_leases: 1} = Retention.prune_all(now)

      released = Repo.get!(RunAttempt, before.id)

      # The pair, stated as a pair: `run_attempts_lease_pairing` allows both
      # null or both set and nothing between, so an owner left behind with no
      # expiry — the stale claim that looks current forever — cannot survive.
      assert released.lease_owner == nil
      assert released.lease_expires_at == nil

      # The fence orders leases so a superseded worker's late events fail
      # closed. It is `null: false`, must stay positive, and is unique within
      # its run; this rule has no business touching it.
      assert released.fence_token == before.fence_token

      # `updated_at` is the instant this rule measures "finished" from, so the
      # release deliberately does not bump it: overwriting it would erase when
      # the attempt ended and make a released row look freshly written.
      assert released.updated_at == before.updated_at

      # Everything else compared as one value, so a field this rule must not
      # move fails the test without having to be named individually.
      assert scrubbed(released) == scrubbed(before)
    end

    test "does not count a terminal attempt that never held a claim", context do
      now = truncated_now()

      unleased =
        planted_attempt(context, lease_owner: nil, at: DateTime.add(now, -@window, :second))

      assert unleased.lease_owner == nil
      assert unleased.lease_expires_at == nil

      assert %{released_delivery_attempt_leases: 0} = Retention.prune_all(now)

      assert scrubbed(Repo.get!(RunAttempt, unleased.id)) == scrubbed(unleased)
    end

    test "reports nothing on a second sweep", context do
      now = truncated_now()
      due = planted_attempt(context, at: DateTime.add(now, -@window, :second))

      assert %{released_delivery_attempt_leases: 1} = Retention.prune_all(now)
      assert %{released_delivery_attempt_leases: 0} = Retention.prune_all(now)

      assert Repo.get!(RunAttempt, due.id).lease_owner == nil
    end
  end

  defp truncated_now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  # Everything except the two columns the release owns, so struct equality can
  # stand in for "no other field moved".
  defp scrubbed(%RunAttempt{} = attempt),
    do: %{attempt | lease_owner: nil, lease_expires_at: nil}

  # A terminal attempt still holding a lease cannot be produced through the
  # changesets, and that is the point: `transition_changeset/3` releases the
  # lease on the way into a terminal state and `claim_lease_changeset/4` refuses
  # a terminal attempt, so the rule exists for claims that survived a path the
  # current writers do not take — an interrupted transition, an older writer, a
  # restored row. The state and the timestamps are planted directly for the same
  # reason Task 1's fixtures are: the changesets always write from the live
  # clock, and the boundary is exactly what is being proved.
  #
  # Each attempt gets its own run, because `run_attempts_one_current_attempt`
  # permits at most one non-terminal attempt per run and the current-state cases
  # plant three.
  defp planted_attempt(context, attrs) do
    attrs = Map.new(attrs)

    %{attempt: attempt} =
      DeliveryFixtures.run_with_attempt_fixture(context.project, context.feature)

    at = attrs |> Map.fetch!(:at) |> DateTime.truncate(:second)

    owner =
      Map.get(attrs, :lease_owner, "worker-#{System.unique_integer([:positive])}")

    {1, _} =
      Repo.update_all(
        from(candidate in RunAttempt, where: candidate.id == ^attempt.id),
        set: [
          state: Map.get(attrs, :state, "succeeded"),
          lease_owner: owner,
          lease_expires_at: owner && DateTime.add(at, 300, :second),
          inserted_at: at,
          updated_at: at
        ]
      )

    Repo.get!(RunAttempt, attempt.id)
  end
end
