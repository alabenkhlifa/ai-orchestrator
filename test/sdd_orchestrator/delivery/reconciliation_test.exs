defmodule SddOrchestrator.Delivery.ReconciliationTest do
  @moduledoc """
  Proof for recovery after a restart, a reconnect, or a silence (Task 28).

  Recovery is where at-least-once delivery becomes dangerous: the same run can
  acquire a second executor, a superseded worker can move state nobody expected
  it to touch, and a control-plane restart can quietly drop the instructions it
  was holding. These tests pin the four outcomes that prevent that, and pin what
  each one is allowed to write.

  The two answering outcomes write nothing at all, which is asserted record by
  record rather than by spot check: a stale fence must leave the run, its
  attempts, its feature, its history, and its queue exactly as they were. The
  two superseding outcomes write one commit each, and the retry's commit ends
  the current attempt in the same transaction that creates its successor, so no
  reconciled run ever holds two current attempts.

  Every decision runs against both storage authorities, because a device
  project's recovery is not allowed to behave differently from a hosted one. The
  one exception is stated where it lives: the retry commit is proven against
  PostgreSQL only, because the device adapter checks its one-current-attempt
  invariant against committed state and therefore cannot apply a supersede and
  an insert in the same batch.
  """
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Accounts.DeviceWorkspace

  alias SddOrchestrator.Delivery.{
    CommandOutbox,
    DeliveryStore,
    Feature,
    Reconciliation,
    Retry,
    RunAttempt,
    WorkerProtocol
  }

  alias SddOrchestrator.Delivery.Reconciliation.Decision
  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.DeviceStore.Local
  alias SddOrchestrator.ParticipationDeliveryDouble

  @execution [
    approved_slice: "slice-07",
    repository_base_revision: "a1b2c3d4e5f6a7b8",
    required_checks: [%{"name" => "mix test", "command" => "mix test"}],
    agent_ref: %{"provider" => "configured-agent"},
    worker_ref: %{"target" => "configured-worker"}
  ]

  # A fixed clock: the lease boundary is the whole subject here, so it must not
  # depend on how long a test takes to run.
  @now ~U[2026-07-29 09:00:00Z]
  @lease_seconds 60
  @worker "wrk_alpha"

  setup context do
    for {key, value} <- [
          participation_email_delivery: ParticipationDeliveryDouble,
          delivery_execution: @execution
        ] do
      previous = Application.get_env(:sdd_orchestrator, key)
      Application.put_env(:sdd_orchestrator, key, value)

      on_exit(fn ->
        if previous do
          Application.put_env(:sdd_orchestrator, key, previous)
        else
          Application.delete_env(:sdd_orchestrator, key)
        end
      end)
    end

    ParticipationDeliveryDouble.succeed()

    hosted = DeliveryFixtures.delivery_project_fixture()
    feature = DeliveryFixtures.feature_fixture(hosted.project, hosted.account)

    path =
      Path.join(System.tmp_dir!(), "reconciliation-#{System.unique_integer([:positive])}.dets")

    start_supervised!({Local, path: path})
    on_exit(fn -> File.rm_rf(path) end)

    {:ok, device_workspace} = Devices.establish_workspace()

    authority =
      case context[:authority] do
        :device ->
          # A device-authoritative project's feature lives in the device store,
          # so the world each authority operates on has to be its own.
          {:ok, _written} =
            Devices.commit_delivery(hosted.project.id, [
              {:put, :feature, feature.id, Feature.to_value(feature), nil}
            ])

          %DeviceWorkspace{id: device_workspace.id}

        _hosted ->
          hosted.workspace
      end

    %{
      authority: authority,
      hosted: hosted,
      project: hosted.project,
      feature: feature,
      account: hosted.account
    }
  end

  # Every behaviour below runs twice: once against PostgreSQL and once against
  # the worker-owned device store.
  for authority <- [:hosted, :device] do
    describe "#{authority} continuation" do
      @describetag authority: authority

      setup ctx, do: running(ctx)

      test "the worker holding the current attempt keeps going", ctx do
        before = state(ctx)

        assert {:ok, [decision]} =
                 Reconciliation.reconcile(ctx.authority, ctx.project.id, snapshot(ctx), now: @now)

        assert decision.outcome == :continue
        assert decision.reason == "current_attempt"
        assert decision.branch == ctx.run.branch
        assert decision.workspace == Path.join(ctx.project.id, ctx.run.id)
        assert decision.fence_token == ctx.attempt.fence_token
        refute Decision.stop?(decision)
        refute decision.replay_from

        assert state(ctx) == before
      end

      test "a worker holding events nobody accepted is told where to resume", ctx do
        before = state(ctx)

        snapshot = snapshot(ctx, %{"last_sequence" => 6})

        assert {:ok, [decision]} =
                 Reconciliation.reconcile(ctx.authority, ctx.project.id, snapshot, now: @now)

        assert decision.outcome == :continue
        assert decision.last_sequence == 0
        assert decision.replay_from == 1

        # Being told what to replay is not the same as having replayed it: the
        # attempt's accepted position only moves through event ingestion.
        assert state(ctx) == before
      end

      test "a worker that restarted keeps the attempt its lease still holds", ctx do
        before = state(ctx)

        # The process is gone but the lease is not. Resuming the same attempt
        # under the unchanged fence is the one recovery that cannot produce a
        # second executor.
        snapshot = snapshot(ctx, %{"state" => "stopped"})

        assert {:ok, [decision]} =
                 Reconciliation.reconcile(ctx.authority, ctx.project.id, snapshot, now: @now)

        assert decision.outcome == :continue
        assert state(ctx) == before
      end
    end

    describe "#{authority} fencing" do
      @describetag authority: authority

      setup ctx, do: running(ctx)

      test "a superseded fence changes nothing at all", ctx do
        ctx = superseded(ctx)
        before = state(ctx)

        # The worker still holds attempt 1 and fence 1; the run moved to 2.
        assert {:ok, [decision]} =
                 Reconciliation.reconcile(ctx.authority, ctx.project.id, snapshot(ctx), now: @now)

        assert decision.outcome == :fence_stale_worker
        assert decision.reason == "stale_fence"
        assert Decision.stop?(decision)

        assert state(ctx) == before
      end

      test "a snapshot from another worker never moves the run", ctx do
        before = state(ctx)
        snapshot = %{snapshot(ctx) | "worker_id" => "wrk_someone_else"}

        assert {:ok, [decision]} =
                 Reconciliation.reconcile(ctx.authority, ctx.project.id, snapshot, now: @now)

        assert decision.outcome == :fence_stale_worker
        assert decision.reason == "other_worker"

        # No migration and no retry: a second worker is stopped, never adopted.
        assert state(ctx) == before
      end

      test "a branch the run does not own is stopped", ctx do
        before = state(ctx)
        snapshot = snapshot(ctx, %{"branch" => "sdd/somewhere-else"})

        assert {:ok, [decision]} =
                 Reconciliation.reconcile(ctx.authority, ctx.project.id, snapshot, now: @now)

        assert decision.outcome == :fence_stale_worker
        assert decision.reason == "branch_mismatch"
        assert state(ctx) == before
      end

      test "a run this project does not own names a workspace nobody can reconcile", ctx do
        before = state(ctx)
        stranger = Ecto.UUID.generate()
        snapshot = snapshot(ctx, %{"run_id" => stranger})

        assert {:ok, [decision]} =
                 Reconciliation.reconcile(ctx.authority, ctx.project.id, snapshot, now: @now)

        assert decision.outcome == :fence_stale_worker
        assert decision.reason == "unknown_run"
        assert decision.workspace == Path.join(ctx.project.id, stranger)
        assert state(ctx) == before
      end

      test "a run whose attempts have all ended is stopped", ctx do
        {:ok, _ended} =
          DeliveryStore.commit(ctx.authority, ctx.project.id, [
            {:attempt, {:transition_attempt, ctx.attempt, "superseded"}}
          ])

        before = state(ctx)

        assert {:ok, [decision]} =
                 Reconciliation.reconcile(ctx.authority, ctx.project.id, snapshot(ctx), now: @now)

        assert decision.outcome == :fence_stale_worker
        assert decision.reason == "no_current_attempt"
        assert state(ctx) == before
      end

      test "an expired lease with a live process is stopped before anything moves", ctx do
        before = state(ctx)

        # The workspace is still occupied. Superseding now would put the next
        # attempt into a directory another process is writing to.
        assert {:ok, [decision]} =
                 Reconciliation.reconcile(ctx.authority, ctx.project.id, snapshot(ctx),
                   now: later()
                 )

        assert decision.outcome == :fence_stale_worker
        assert decision.reason == "live_process_without_lease"
        assert state(ctx) == before
      end
    end

    describe "#{authority} expired lease" do
      @describetag authority: authority

      setup ctx, do: running(ctx)

      test "decides the next bounded retry on the same run, branch, and workspace", ctx do
        before = state(ctx)
        snapshot = snapshot(ctx, %{"state" => "stopped"})

        assert {:ok, [decision]} =
                 Reconciliation.decide(ctx.authority, ctx.project.id, snapshot,
                   now: later(),
                   jitter: 0.0
                 )

        assert decision.outcome == :schedule_retry
        assert decision.reason == "lease_expired"
        assert decision.branch == ctx.run.branch
        assert decision.workspace == Path.join(ctx.project.id, ctx.run.id)
        assert decision.attempt_number == ctx.attempt.attempt_number
        assert decision.fence_token == ctx.attempt.fence_token

        # The schedule is the retry path's own, not a second curve invented here.
        assert decision.due_at == DateTime.add(later(), Retry.backoff(1, jitter: 0.0), :second)
        assert DateTime.compare(decision.due_at, later()) == :gt

        # Deciding is not applying: the run is untouched until the commit runs.
        assert decision.results == %{}
        assert state(ctx) == before
      end
    end

    describe "#{authority} exhausted budget" do
      @describetag authority: authority

      setup ctx, do: ctx |> running() |> exhausted()

      test "stops the run and shows a visible failure", ctx do
        snapshot = snapshot(ctx, %{"state" => "stopped"})

        assert {:ok, [decision]} =
                 Reconciliation.reconcile(ctx.authority, ctx.project.id, snapshot, now: later())

        assert decision.outcome == :terminal
        assert decision.reason == "budget_exhausted"

        {:ok, run} = DeliveryStore.fetch_run(ctx.authority, ctx.project.id, ctx.run.id)
        assert run.state == "failed"
        assert run.failure_reason == "worker_unavailable"

        assert decision.results.attempt.state == "failed"
        assert decision.results.activity.payload["outcome"] == "terminal"
      end

      test "leaves the feature in development with a failed status", ctx do
        snapshot = snapshot(ctx, %{"state" => "stopped"})

        {:ok, [_decision]} =
          Reconciliation.reconcile(ctx.authority, ctx.project.id, snapshot, now: later())

        {:ok, feature} =
          DeliveryStore.fetch_feature(ctx.authority, ctx.project.id, ctx.feature.id)

        # The work stopped where it was; it did not move back to a stage a
        # reader already saw it leave.
        assert feature.lifecycle_column == "in_development"
        assert feature.status == "failed"
      end

      test "queues nothing that could start a further attempt", ctx do
        snapshot = snapshot(ctx, %{"state" => "stopped"})

        {:ok, [decision]} =
          Reconciliation.reconcile(ctx.authority, ctx.project.id, snapshot, now: later())

        refute Map.has_key?(decision.results, :command)
        assert commands(ctx) == []
        assert Enum.all?(attempts(ctx), fn {_number, state, _fence} -> state != "pending" end)
      end
    end

    describe "#{authority} control-plane restart" do
      @describetag authority: authority

      setup ctx, do: running(ctx)

      test "returns claims a dead dispatcher abandoned without touching the run", ctx do
        command = abandoned_claim(ctx)
        before = state(ctx)

        assert {:ok, recovered} = Reconciliation.recover(ctx.authority, now: expiry())

        assert recovered.released >= 1
        assert recovered.pending >= 1
        assert recovered.at == expiry()

        # The queue is rows, so recovery is a query rather than a rebuilt
        # in-memory list, and it moves no project state.
        assert {:ok, returned} = CommandOutbox.fetch(command.id)
        assert returned.state == "pending"
        refute returned.claimed_by
        assert state(ctx) == before
      end

      test "reports nothing recovered when no claim expired", ctx do
        _claimed = abandoned_claim(ctx)

        assert {:ok, recovered} = Reconciliation.recover(ctx.authority, now: issued())
        assert recovered.released == 0
      end
    end
  end

  # The retry commit is proven against PostgreSQL only. The device adapter
  # checks its one-current-attempt invariant against committed state before it
  # applies a batch, so it cannot express a supersede and an insert in the same
  # commit — and reconciliation may not create the next attempt outside the
  # commit that ends the current one. The decision itself is proven against both
  # authorities above.
  describe "hosted retry commit" do
    setup ctx, do: running(ctx)

    test "schedules the next bounded retry on the same run, branch, and workspace", ctx do
      snapshot = snapshot(ctx, %{"state" => "stopped"})

      assert {:ok, [decision]} =
               Reconciliation.reconcile(ctx.authority, ctx.project.id, snapshot,
                 now: later(),
                 jitter: 0.0
               )

      assert decision.outcome == :schedule_retry

      command = decision.results.command
      assert command.operation == "retry"
      assert command.run_id == ctx.run.id
      assert DateTime.compare(command.due_at, decision.due_at) == :eq
      assert DateTime.compare(command.due_at, later()) == :gt

      next = decision.results.attempt
      assert next.attempt_number == 2
      assert next.fence_token == ctx.attempt.fence_token + 1
      assert next.run_id == ctx.run.id
      assert command.attempt_id == next.id

      {:ok, run} = DeliveryStore.fetch_run(ctx.authority, ctx.project.id, ctx.run.id)
      assert run.branch == ctx.run.branch
      assert run.current_attempt_number == 2
      assert run.state == "running"
    end

    test "ends the current attempt in the commit that creates its successor", ctx do
      snapshot = snapshot(ctx, %{"state" => "stopped"})

      assert {:ok, [decision]} =
               Reconciliation.reconcile(ctx.authority, ctx.project.id, snapshot, now: later())

      # One superseded attempt, one new attempt, and never two current ones.
      assert attempts(ctx) == [{1, "superseded", 1}, {2, "pending", 2}]

      assert {:ok, current} =
               DeliveryStore.current_attempt(ctx.authority, ctx.project.id, ctx.run.id)

      assert current.id == decision.results.attempt.id
      assert Enum.count(attempts(ctx), fn {_number, state, _fence} -> state == "pending" end) == 1
    end

    test "the superseded worker cannot schedule a second retry by reporting again", ctx do
      snapshot = snapshot(ctx, %{"state" => "stopped"})

      assert {:ok, [_first]} =
               Reconciliation.reconcile(ctx.authority, ctx.project.id, snapshot, now: later())

      before = state(ctx)

      assert {:ok, [replayed]} =
               Reconciliation.reconcile(ctx.authority, ctx.project.id, snapshot, now: later())

      assert replayed.outcome == :fence_stale_worker
      assert replayed.reason == "stale_fence"
      assert state(ctx) == before
    end

    test "records the recovery in the feature's history", ctx do
      snapshot = snapshot(ctx, %{"state" => "stopped"})

      {:ok, [decision]} =
        Reconciliation.reconcile(ctx.authority, ctx.project.id, snapshot, now: later())

      entry = decision.results.activity
      assert entry.type == "reconciled"
      assert entry.actor_kind == "system"
      assert entry.payload["outcome"] == "schedule_retry"
      assert entry.payload["branch"] == ctx.run.branch
      assert entry.payload["workspace"] == Path.join(ctx.project.id, ctx.run.id)
      assert entry.payload["prior_attempt_number"] == 1
      assert entry.payload["attempt_number"] == 2

      # The worker's opaque identity is not project history: the attempt and its
      # fence already say which execution this was.
      refute Map.has_key?(entry.payload, "worker_id")
    end

    test "leaves the feature where it is while the run continues", ctx do
      snapshot = snapshot(ctx, %{"state" => "stopped"})

      {:ok, [_decision]} =
        Reconciliation.reconcile(ctx.authority, ctx.project.id, snapshot, now: later())

      {:ok, feature} = DeliveryStore.fetch_feature(ctx.authority, ctx.project.id, ctx.feature.id)

      assert feature.lifecycle_column == "in_development"
      assert feature.status == "none"
    end
  end

  describe "refusals" do
    setup ctx, do: running(ctx)

    test "an envelope that is not a reconciliation snapshot is refused", ctx do
      heartbeat = %{
        "type" => "heartbeat",
        "protocol_version" => WorkerProtocol.version(),
        "run_id" => ctx.run.id,
        "worker_id" => @worker,
        "attempt_number" => 1,
        "fence_token" => 1,
        "last_sequence" => 0,
        "state" => "running",
        "observed_at" => "2026-07-29T09:00:00Z"
      }

      assert {:error, :invalid_snapshot} =
               Reconciliation.reconcile(ctx.authority, ctx.project.id, heartbeat, now: @now)
    end

    test "a snapshot the codec rejects changes nothing", ctx do
      before = state(ctx)
      snapshot = snapshot(ctx, %{"fence_token" => 0})

      assert {:error, :invalid_ordering_value} =
               Reconciliation.reconcile(ctx.authority, ctx.project.id, snapshot, now: @now)

      assert {:error, :invalid_ordering_value} =
               Reconciliation.decide(ctx.authority, ctx.project.id, snapshot, now: @now)

      assert state(ctx) == before
    end

    test "an authority it cannot resolve fails closed", ctx do
      assert {:error, :unsupported_authority} =
               Reconciliation.reconcile(:nonsense, ctx.project.id, snapshot(ctx), now: @now)

      assert {:error, :unsupported_authority} = Reconciliation.recover(:nonsense)
    end
  end

  describe "deciding without applying" do
    setup ctx, do: running(ctx)

    test "reaches the retry outcome and writes none of it", ctx do
      before = state(ctx)
      snapshot = snapshot(ctx, %{"state" => "stopped"})

      assert {:ok, [decision]} =
               Reconciliation.decide(ctx.authority, ctx.project.id, snapshot, now: later())

      assert decision.outcome == :schedule_retry
      assert decision.results == %{}
      assert state(ctx) == before
    end

    test "answers one decision per reported attempt", ctx do
      other = %{
        "run_id" => Ecto.UUID.generate(),
        "attempt_number" => 1,
        "command_id" => command_id(),
        "fence_token" => 1,
        "last_sequence" => 0,
        "branch" => "sdd/other",
        "state" => "running"
      }

      snapshot = %{snapshot(ctx) | "attempts" => [reported(ctx), other]}

      assert {:ok, [mine, stranger]} =
               Reconciliation.decide(ctx.authority, ctx.project.id, snapshot, now: @now)

      assert mine.outcome == :continue
      assert stranger.outcome == :fence_stale_worker
      assert stranger.reason == "unknown_run"
    end
  end

  # One run with one leased, dispatched attempt on a feature that is in
  # development: the state every reconnect is compared against.
  defp running(%{authority: authority, project: project, feature: feature} = ctx) do
    unique = System.unique_integer([:positive])
    digest = DeliveryFixtures.digest("rev-#{unique}")
    branch = "sdd/run-#{unique}"

    {:ok, %{run: run, attempt: attempt}} =
      DeliveryStore.commit(authority, project.id, [
        {:run,
         {:insert_run,
          %{
            project_id: project.id,
            feature_id: feature.id,
            starting_revision_id: "rev-#{unique}",
            starting_revision_digest: digest,
            approved_slice: "slice-07",
            branch: branch
          }}},
        {:attempt,
         {:insert_attempt,
          %{
            run_id: {:ref, :run, :id},
            attempt_number: 1,
            continuation_reason: "initial",
            effective_revision_id: "rev-#{unique}",
            effective_revision_digest: digest,
            manifest_digest: DeliveryFixtures.digest("manifest-#{unique}"),
            fence_token: 1
          }}},
        {:activity,
         {:append_activity,
          %{
            project_id: project.id,
            feature_id: feature.id,
            run_id: {:ref, :run, :id},
            attempt_id: {:ref, :attempt, :id},
            actor_kind: "system",
            type: "run_started",
            payload: %{"branch" => branch}
          }}}
      ])

    {:ok, %{feature: ready}} =
      DeliveryStore.commit(authority, project.id, [
        {:feature, {:transition_feature, feature, "ready_for_development", []}}
      ])

    {:ok, %{feature: developing}} =
      DeliveryStore.commit(authority, project.id, [
        {:feature, {:transition_feature, ready, "in_development", []}}
      ])

    {:ok, %{attempt: dispatched, run: started}} =
      DeliveryStore.commit(authority, project.id, [
        {:attempt, {:transition_attempt, attempt, "dispatched"}},
        {:run, {:transition_run, run, "running", []}}
      ])

    Map.merge(ctx, %{run: started, attempt: lease(ctx, dispatched), feature: developing})
  end

  # The same run after its automatic budget is spent: attempt four is current,
  # and nothing after it may be scheduled.
  defp exhausted(%{authority: authority, project: project, run: run} = ctx) do
    number = Retry.budget() + 1

    {:ok, _superseded} =
      DeliveryStore.commit(authority, project.id, [
        {:attempt, {:transition_attempt, ctx.attempt, "superseded"}}
      ])

    {:ok, %{run: advanced}} =
      DeliveryStore.commit(authority, project.id, [
        {:run, {:advance_attempt_number, run, number}}
      ])

    {:ok, %{attempt: latest}} =
      DeliveryStore.commit(authority, project.id, [
        {:attempt,
         {:insert_attempt,
          %{
            run_id: run.id,
            attempt_number: number,
            continuation_reason: "automatic_retry",
            effective_revision_id: run.effective_revision_id,
            effective_revision_digest: run.effective_revision_digest,
            manifest_digest: DeliveryFixtures.digest("manifest-#{run.id}-#{number}"),
            fence_token: number
          }}}
      ])

    {:ok, %{attempt: dispatched}} =
      DeliveryStore.commit(authority, project.id, [
        {:attempt, {:transition_attempt, latest, "dispatched"}}
      ])

    Map.merge(ctx, %{run: advanced, attempt: lease(ctx, dispatched)})
  end

  defp lease(%{authority: authority, project: project}, attempt) do
    expires_at = DateTime.add(@now, @lease_seconds, :second)

    {:ok, %{attempt: leased}} =
      DeliveryStore.commit(authority, project.id, [
        {:attempt, {:claim_lease, attempt, @worker, expires_at}}
      ])

    true = RunAttempt.lease_active?(leased, @now)

    leased
  end

  # The run one attempt further on: the worker still holds fence 1 while the
  # authoritative current attempt is 2.
  defp superseded(%{authority: authority, project: project, run: run, attempt: attempt} = ctx) do
    {:ok, _ended} =
      DeliveryStore.commit(authority, project.id, [
        {:attempt, {:transition_attempt, attempt, "superseded"}}
      ])

    {:ok, %{run: advanced}} =
      DeliveryStore.commit(authority, project.id, [
        {:run, {:advance_attempt_number, run, 2}}
      ])

    {:ok, %{attempt: next}} =
      DeliveryStore.commit(authority, project.id, [
        {:attempt,
         {:insert_attempt,
          %{
            run_id: run.id,
            attempt_number: 2,
            continuation_reason: "automatic_retry",
            effective_revision_id: run.effective_revision_id,
            effective_revision_digest: run.effective_revision_digest,
            manifest_digest: DeliveryFixtures.digest("manifest-#{run.id}-2"),
            fence_token: 2
          }}}
      ])

    Map.merge(ctx, %{run: advanced, next_attempt: next})
  end

  # One claimed command whose dispatcher never came back. The queue is hosted
  # for every project, because that is where this control plane's own
  # instructions live.
  defp abandoned_claim(%{project: project, feature: feature}) do
    run = DeliveryFixtures.run_fixture(project, feature)

    {:ok, command} =
      CommandOutbox.enqueue(%{
        id: Ecto.UUID.generate(),
        project_id: project.id,
        run_id: run.id,
        operation: "cancel",
        expected_state_version: run.state_version,
        due_at: issued()
      })

    [claimed] =
      CommandOutbox.claim("dispatcher-gone", now: issued(), lease_seconds: @lease_seconds)

    assert claimed.id == command.id

    command
  end

  defp snapshot(ctx, overrides \\ %{}) do
    %{
      "type" => "reconciliation_snapshot",
      "protocol_version" => WorkerProtocol.version(),
      "worker_id" => @worker,
      "observed_at" => "2026-07-29T09:00:30Z",
      "attempts" => [reported(ctx, overrides)]
    }
  end

  defp reported(ctx, overrides \\ %{}) do
    Map.merge(
      %{
        "run_id" => ctx.run.id,
        "attempt_number" => ctx.attempt.attempt_number,
        "command_id" => command_id(),
        "fence_token" => ctx.attempt.fence_token,
        "last_sequence" => ctx.attempt.last_sequence,
        "branch" => ctx.run.branch,
        "state" => "running"
      },
      Map.new(overrides)
    )
  end

  defp command_id, do: "cmd-#{System.unique_integer([:positive])}"

  # After the lease expired, which is the only time an attempt may be superseded
  # without proving a live process is gone by other means.
  defp later, do: DateTime.add(@now, @lease_seconds + 1, :second)

  # The outbox records command times at microsecond precision, so the queue's
  # own clock is stated at that precision rather than truncated to the second
  # the attempt lease uses.
  defp issued, do: %{@now | microsecond: {0, 6}}

  defp expiry, do: %{later() | microsecond: {0, 6}}

  # Everything one reconciliation could possibly have written, read back through
  # the authority under test.
  defp state(ctx) do
    {:ok, run} = DeliveryStore.fetch_run(ctx.authority, ctx.project.id, ctx.run.id)
    {:ok, feature} = DeliveryStore.fetch_feature(ctx.authority, ctx.project.id, ctx.feature.id)

    %{
      run: {run.state, run.current_attempt_number, run.state_version, run.failure_reason},
      feature: {feature.lifecycle_column, feature.status, feature.state_version},
      attempts: attempts(ctx),
      activity:
        ctx.authority
        |> DeliveryStore.list_activity(ctx.project.id, ctx.feature.id)
        |> Enum.map(&{&1.sequence, &1.type}),
      commands: commands(ctx)
    }
  end

  defp attempts(%{authority: %DeviceWorkspace{}} = ctx) do
    ctx.project.id
    |> Devices.list_delivery(:attempt)
    |> Enum.filter(&(&1["run_id"] == ctx.run.id))
    |> Enum.map(&{&1["attempt_number"], &1["state"], &1["fence_token"]})
    |> Enum.sort()
  end

  defp attempts(ctx) do
    RunAttempt
    |> where([a], a.run_id == ^ctx.run.id)
    |> Repo.all()
    |> Enum.map(&{&1.attempt_number, &1.state, &1.fence_token})
    |> Enum.sort()
  end

  defp commands(%{authority: %DeviceWorkspace{}} = ctx) do
    ctx.project.id
    |> Devices.list_delivery(:command)
    |> Enum.filter(&(&1["run_id"] == ctx.run.id))
    |> Enum.map(& &1["operation"])
    |> Enum.sort()
  end

  defp commands(ctx) do
    ctx.run.id
    |> CommandOutbox.for_run()
    |> Enum.map(& &1.operation)
    |> Enum.sort()
  end
end
