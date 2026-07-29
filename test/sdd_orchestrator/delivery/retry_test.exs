defmodule SddOrchestrator.Delivery.RetryTest do
  @moduledoc """
  Proof for bounded automatic and manual retry (Task 25).

  Recovery is where a product quietly becomes expensive: retrying a failure that
  will never succeed, retrying forever, or retrying somewhere else and losing the
  work. These tests pin the three boundaries that prevent that — an explicit
  classification that fails closed, a budget of three automatic retries after the
  initial attempt, and the same run, branch, and workspace throughout.

  They also pin what a terminal failure must *not* do: it stops the run, shows a
  visible `Failed` status, leaves the feature in `In development`, and queues no
  instruction that could start another attempt behind a participant's back.
  """
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Delivery.{
    ActivityEntry,
    AgentRun,
    CommandOutbox,
    DeliveryStore,
    Feature,
    Retry,
    RunAttempt,
    RunCommand,
    WorkerProtocol
  }

  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.ParticipationDeliveryDouble
  alias SddOrchestrator.Repo

  @execution [
    approved_slice: "slice-07",
    repository_base_revision: "a1b2c3d4e5f6a7b8",
    required_checks: [%{"name" => "mix test", "command" => "mix test"}],
    agent_ref: %{"provider" => "configured-agent"},
    worker_ref: %{"target" => "configured-worker"}
  ]

  setup do
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

    context = DeliveryFixtures.delivery_project_fixture()
    feature = DeliveryFixtures.feature_fixture(context.project, context.account)

    %{
      context: context,
      authority: context.workspace,
      project: context.project,
      feature: feature,
      owner: context.owner_actor,
      participant: context.participant_actor,
      owner_account: context.account
    }
  end

  describe "classification" do
    test "only a failure another attempt can fix is retryable" do
      for reason <- Retry.retryable_reasons() do
        assert Retry.classify(reason) == :retryable
      end

      assert "transport_lost" in Retry.retryable_reasons()
      assert "rate_limited" in Retry.retryable_reasons()
    end

    test "a failure that would fail identically again is terminal" do
      for reason <- Retry.terminal_reasons() do
        assert Retry.classify(reason) == :terminal
      end

      assert "invalid_authorization" in Retry.terminal_reasons()
      assert "unsafe_workspace" in Retry.terminal_reasons()
    end

    test "an unrecognised reason fails closed" do
      # Never retry what nobody classified: the budget would be spent
      # rediscovering an answer that was already final.
      assert Retry.classify("something_new") == :terminal
      assert Retry.classify("") == :terminal
      assert Retry.classify(nil) == :terminal
      assert Retry.classify(%{"code" => "transport_lost"}) == :terminal
    end
  end

  describe "timing" do
    test "the schedule is exponential from 15 seconds" do
      assert Retry.backoff(1, jitter: 0.0) == 15
      assert Retry.backoff(2, jitter: 0.0) == 30
      assert Retry.backoff(3, jitter: 0.0) == 60
      assert Retry.backoff(4, jitter: 0.0) == 120
    end

    test "the delay never exceeds the five-minute cap" do
      assert Retry.backoff(5, jitter: 0.0) == 240
      assert Retry.backoff(6, jitter: 0.0) == 300
      assert Retry.backoff(40, jitter: 0.0) == 300

      # Jitter is applied before the cap, so it cannot push a delay past it.
      assert Retry.backoff(5, jitter: 0.5) == 300
      assert Retry.backoff(40, jitter: 0.5) == 300
    end

    test "jitter spreads a wave of failures without going below the floor" do
      delays = for _draw <- 1..200, do: Retry.backoff(1)

      assert Enum.all?(delays, &(&1 >= 15 and &1 <= 300))
      assert Enum.uniq(delays) != [15]

      # A caller cannot shorten the wait by naming a negative or nonsense jitter.
      assert Retry.backoff(1, jitter: -5.0) == 15
      assert Retry.backoff(1, jitter: :nonsense) == 15
    end
  end

  describe "scheduling one automatic retry" do
    setup ctx, do: running(ctx)

    test "waits by scheduling, never by sleeping", %{
      authority: authority,
      project: project,
      run: run,
      attempt: attempt
    } do
      before = DateTime.utc_now()

      {:ok, results} =
        Retry.handle_failure(
          authority,
          project.id,
          failed_event(run, attempt, "transport_lost"),
          jitter: 0.0
        )

      assert DateTime.diff(results.command.due_at, before) >= 15
      assert results.command.operation == "retry"
      assert results.command.state == "pending"

      # The row exists but nothing can claim it yet, which is what makes the
      # wait survive a control-plane restart.
      assert Repo.aggregate(RunCommand, :count) == 1
      assert CommandOutbox.pending_count() == 0
    end

    test "continues the same run, branch, and workspace", %{
      authority: authority,
      project: project,
      run: run,
      attempt: attempt
    } do
      {:ok, results} =
        Retry.handle_failure(authority, project.id, failed_event(run, attempt, "rate_limited"))

      assert results.run.id == run.id
      assert results.run.branch == run.branch
      assert results.attempt.run_id == run.id

      # The workspace is derived from the run identity, so preserving the run is
      # what preserves the workspace the failed work is sitting in.
      assert Repo.get!(AgentRun, run.id).branch == run.branch
    end

    test "keeps the retry on the configured worker rather than moving it", %{
      authority: authority,
      project: project,
      run: run,
      attempt: attempt
    } do
      {:ok, results} =
        Retry.handle_failure(authority, project.id, failed_event(run, attempt, "rate_limited"))

      # The manifest handed to the worker is rebuilt from the run and the project
      # configuration, never from the failure, so the same configured worker and
      # the same branch are bound into the digest the command carries.
      assert results.command.manifest_digest == results.attempt.manifest_digest
      refute results.attempt.manifest_digest == attempt.manifest_digest
    end

    test "creates the next ordered attempt with a higher fence token", %{
      authority: authority,
      project: project,
      run: run,
      attempt: attempt
    } do
      {:ok, results} =
        Retry.handle_failure(
          authority,
          project.id,
          failed_event(run, attempt, "worker_unavailable")
        )

      assert results.attempt.attempt_number == attempt.attempt_number + 1
      assert results.attempt.fence_token > attempt.fence_token
      assert results.attempt.continuation_reason == "automatic_retry"
      assert results.run.current_attempt_number == results.attempt.attempt_number

      # The failed attempt is terminal, so the old worker's fence is useless
      # even if it reconnects believing it still owns the run.
      assert Repo.get!(RunAttempt, attempt.id).state == "failed"
      assert current_attempts(run) == 1
    end

    test "keeps the feature in development with nothing to report yet", %{
      authority: authority,
      project: project,
      feature: feature,
      run: run,
      attempt: attempt
    } do
      {:ok, _results} =
        Retry.handle_failure(authority, project.id, failed_event(run, attempt, "transport_lost"))

      stored = Repo.get!(Feature, feature.id)

      assert stored.lifecycle_column == "in_development"
      assert stored.status == "none"
      assert Repo.get!(AgentRun, run.id).state == "running"
    end

    test "preserves the progress and checkpoint the failed attempt produced", %{
      authority: authority,
      project: project,
      feature: feature,
      run: run,
      attempt: attempt
    } do
      progress =
        DeliveryFixtures.activity_fixture(project, feature, %{
          run_id: run.id,
          attempt_id: attempt.id,
          type: "progress",
          payload: %{"checkpoint" => "search-index"}
        })

      {:ok, results} =
        Retry.handle_failure(authority, project.id, failed_event(run, attempt, "transport_lost"))

      # Nothing accepted is discarded: the earlier history, the failed attempt
      # record, and its manifest all survive the continuation.
      assert Repo.get!(ActivityEntry, progress.id).payload["checkpoint"] == "search-index"
      assert Repo.get!(RunAttempt, attempt.id).manifest_digest == attempt.manifest_digest

      # And the next attempt is reconstructable without a live provider thread.
      assert results.attempt.manifest_digest
      refute results.attempt |> RunAttempt.to_value() |> Jason.encode!() =~ "thread"
    end

    test "records the retry in history with its reason", %{
      authority: authority,
      project: project,
      run: run,
      attempt: attempt
    } do
      {:ok, results} =
        Retry.handle_failure(
          authority,
          project.id,
          failed_event(run, attempt, "provider_unavailable"),
          jitter: 0.0
        )

      assert results.activity.type == "retry_scheduled"
      assert results.activity.actor_kind == "system"
      assert results.activity.payload["failure_reason"] == "provider_unavailable"
      assert results.activity.payload["retry_number"] == 1
      assert results.activity.payload["attempt_number"] == 2
      assert results.activity.payload["branch"] == run.branch
    end
  end

  describe "the retry budget" do
    setup ctx, do: running(ctx)

    test "three automatic retries follow the initial attempt, then it stops", %{
      authority: authority,
      project: project,
      feature: feature,
      run: run,
      attempt: attempt
    } do
      {stopped, _last} =
        Enum.reduce(1..4, {run, attempt}, fn _n, acc -> fail(authority, project, acc) end)

      # Four attempts exist: the initial one and exactly three retries.
      assert Repo.aggregate(RunAttempt, :count) == 4
      assert Enum.map(attempts(run), & &1.attempt_number) == [1, 2, 3, 4]

      assert Enum.map(attempts(run), & &1.continuation_reason) |> Enum.uniq() == [
               "initial",
               "automatic_retry"
             ]

      # Three retry commands, and none for the fourth failure.
      assert Repo.aggregate(RunCommand, :count) == 3

      assert Repo.get!(AgentRun, stopped.id).state == "failed"
      assert Repo.get!(AgentRun, stopped.id).failure_reason == "transport_lost"
      assert Repo.get!(Feature, feature.id).status == "failed"
      assert Repo.get!(Feature, feature.id).lifecycle_column == "in_development"
    end

    test "the budget counts the run's own ordering, not the worker's claim", %{run: run} do
      assert Retry.budget() == 3

      refute Retry.exhausted?(%{run | current_attempt_number: 1}, 1)
      refute Retry.exhausted?(%{run | current_attempt_number: 3}, 3)
      assert Retry.exhausted?(%{run | current_attempt_number: 4}, 4)

      # A worker naming an older attempt cannot buy itself extra retries.
      assert Retry.exhausted?(%{run | current_attempt_number: 4}, 1)
    end
  end

  describe "a terminal failure" do
    setup ctx, do: running(ctx)

    test "stops the run and shows the reason without leaving development", %{
      authority: authority,
      project: project,
      feature: feature,
      run: run,
      attempt: attempt
    } do
      {:ok, results} =
        Retry.handle_failure(
          authority,
          project.id,
          failed_event(run, attempt, "missing_configuration")
        )

      assert results.run.state == "failed"
      assert results.run.failure_reason == "missing_configuration"

      # `Failed` is a status, never a column: the work stopped where it was.
      assert results.feature.status == "failed"
      assert results.feature.lifecycle_column == "in_development"
      assert Repo.get!(Feature, feature.id).lifecycle_column == "in_development"
      assert Repo.get!(RunAttempt, attempt.id).state == "failed"
    end

    test "enqueues nothing that could start another attempt", %{
      authority: authority,
      project: project,
      run: run,
      attempt: attempt
    } do
      {:ok, results} =
        Retry.handle_failure(
          authority,
          project.id,
          failed_event(run, attempt, "invalid_authorization")
        )

      refute Map.has_key?(results, :command)
      assert Repo.aggregate(RunCommand, :count) == 0
      assert Repo.aggregate(RunAttempt, :count) == 1
    end

    test "records the failure in history", %{
      authority: authority,
      project: project,
      run: run,
      attempt: attempt
    } do
      {:ok, results} =
        Retry.handle_failure(
          authority,
          project.id,
          failed_event(run, attempt, "unsafe_workspace")
        )

      assert results.activity.type == "run_failed"
      assert results.activity.payload["failure_reason"] == "unsafe_workspace"
      assert results.activity.payload["classification"] == "terminal"
      assert results.activity.payload["budget_exhausted"] == false
    end

    test "a failure without a usable reason changes nothing", %{
      authority: authority,
      project: project,
      run: run,
      attempt: attempt
    } do
      oversized = String.duplicate("x", 201)

      assert {:error, :invalid_failure} =
               Retry.handle_failure(authority, project.id, failed_event(run, attempt, oversized))

      assert {:error, :invalid_failure} =
               Retry.handle_failure(authority, project.id, failed_event(run, attempt, ""))

      assert Repo.get!(AgentRun, run.id).state == "running"
      assert Repo.aggregate(RunCommand, :count) == 0
    end
  end

  describe "duplicate and stale failures" do
    setup ctx, do: running(ctx)

    test "a redelivered failure cannot create a second retry", %{
      authority: authority,
      project: project,
      run: run,
      attempt: attempt
    } do
      event = failed_event(run, attempt, "transport_lost")

      {:ok, _results} = Retry.handle_failure(authority, project.id, event)

      # The same envelope arrives again. Its fence belongs to an attempt that is
      # no longer current, so it moves nothing.
      assert {:error, :stale_fence} = Retry.handle_failure(authority, project.id, event)

      assert Repo.aggregate(RunAttempt, :count) == 2
      assert Repo.aggregate(RunCommand, :count) == 1
      assert entries("retry_scheduled") == 1
    end

    test "a redelivered terminal failure cannot fail the run twice", %{
      authority: authority,
      project: project,
      run: run,
      attempt: attempt
    } do
      event = failed_event(run, attempt, "malformed_manifest")

      {:ok, _results} = Retry.handle_failure(authority, project.id, event)

      assert {:error, :no_current_attempt} = Retry.handle_failure(authority, project.id, event)

      assert entries("run_failed") == 1
    end

    test "a superseded worker cannot fail the attempt that replaced it", %{
      authority: authority,
      project: project,
      run: run,
      attempt: attempt
    } do
      {:ok, results} =
        Retry.handle_failure(authority, project.id, failed_event(run, attempt, "rate_limited"))

      stale = failed_event(run, attempt, "unsafe_workspace")

      assert {:error, :stale_fence} = Retry.handle_failure(authority, project.id, stale)
      assert Repo.get!(RunAttempt, results.attempt.id).state == "pending"
      assert Repo.get!(AgentRun, run.id).state == "running"
      assert current_attempts(run) == 1
    end

    test "an event another task owns is refused here", %{
      authority: authority,
      project: project,
      run: run,
      attempt: attempt
    } do
      progress = %{failed_event(run, attempt, "transport_lost") | "event_type" => "progress"}

      assert {:error, :unsupported_event} = Retry.handle_failure(authority, project.id, progress)
    end
  end

  describe "manual retry" do
    setup ctx, do: ctx |> running() |> stopped()

    test "any current participant may start the next attempt", %{
      authority: authority,
      project: project,
      feature: feature,
      participant: participant,
      run: run,
      attempt: attempt
    } do
      # Not the initiator and not the owner: a stopped run is shared work.
      assert {:ok, results} =
               Retry.retry_now(authority, participant, %{project: project, feature: feature})

      assert results.run.id == run.id
      assert results.run.branch == run.branch
      assert results.run.state == "running"
      assert results.run.failure_reason == nil

      assert results.attempt.attempt_number == attempt.attempt_number + 1
      assert results.attempt.fence_token > attempt.fence_token
      assert results.attempt.continuation_reason == "manual_retry"
      assert current_attempts(run) == 1
    end

    test "the feature keeps its column and clears the failed status", %{
      authority: authority,
      project: project,
      feature: feature,
      owner: owner
    } do
      {:ok, results} = Retry.retry_now(authority, owner, %{project: project, feature: feature})

      assert results.feature.status == "none"
      assert results.feature.lifecycle_column == "in_development"
      assert Repo.get!(Feature, feature.id).lifecycle_column == "in_development"
    end

    test "the command is due immediately because a person is waiting", %{
      authority: authority,
      project: project,
      feature: feature,
      owner: owner,
      run: run
    } do
      {:ok, results} = Retry.retry_now(authority, owner, %{project: project, feature: feature})

      assert results.command.operation == "retry"
      assert results.command.run_id == run.id
      assert results.command.manifest_digest == results.attempt.manifest_digest
      assert DateTime.compare(results.command.due_at, DateTime.utc_now()) != :gt
      assert CommandOutbox.pending_count() == 1
    end

    test "the retry is recorded under the participant who asked for it", %{
      authority: authority,
      project: project,
      feature: feature,
      context: context,
      participant: participant
    } do
      {:ok, results} =
        Retry.retry_now(authority, participant, %{project: project, feature: feature})

      assert results.activity.type == "retry_scheduled"
      assert results.activity.actor_kind == "participant"
      assert results.activity.actor_account_id == context.identity.account.id
      assert results.activity.payload["manual"] == true
    end

    test "an outsider is refused without learning the run exists", %{
      authority: authority,
      project: project,
      feature: feature,
      run: run
    } do
      assert {:error, :unauthorized} =
               Retry.retry_now(authority, %{account_id: Ecto.UUID.generate()}, %{
                 project: project,
                 feature: feature
               })

      assert Repo.get!(AgentRun, run.id).state == "failed"
      assert Repo.aggregate(RunAttempt, :count) == 1
      assert Repo.aggregate(RunCommand, :count) == 0
    end

    test "two participants pressing retry produce one attempt, not two", %{
      authority: authority,
      project: project,
      feature: feature,
      owner: owner,
      participant: participant,
      run: run
    } do
      {:ok, _first} = Retry.retry_now(authority, owner, %{project: project, feature: feature})

      # The run is running again, so there is no failed run left to retry. That
      # is what stops two participants racing into competing attempts.
      assert {:error, :no_failed_run} =
               Retry.retry_now(authority, participant, %{project: project, feature: feature})

      assert Repo.aggregate(RunAttempt, :count) == 2
      assert current_attempts(run) == 1
      assert Repo.aggregate(RunCommand, :count) == 1
    end

    test "a feature with no failed run offers nothing to retry", %{
      authority: authority,
      project: project,
      owner: owner,
      context: context
    } do
      other = DeliveryFixtures.feature_fixture(project, context.account)

      assert {:error, :no_failed_run} =
               Retry.retry_now(authority, owner, %{project: project, feature: other})

      assert {:ok, nil} = Retry.pending(authority, owner, %{project: project, feature: other})
    end

    test "the screen sees the failed run only while it is still failed", %{
      authority: authority,
      project: project,
      feature: feature,
      owner: owner,
      run: run
    } do
      assert {:ok, %AgentRun{id: found}} =
               Retry.pending(authority, owner, %{project: project, feature: feature})

      assert found == run.id

      {:ok, _results} = Retry.retry_now(authority, owner, %{project: project, feature: feature})

      assert {:ok, nil} = Retry.pending(authority, owner, %{project: project, feature: feature})

      assert {:error, :unauthorized} =
               Retry.pending(authority, %{account_id: Ecto.UUID.generate()}, %{
                 project: project,
                 feature: feature
               })
    end
  end

  # A running run with one dispatched attempt: the state every failure starts
  # from. Built through the real store steps rather than by inserting rows, so
  # the fixtures cannot drift from the product.
  defp running(%{authority: authority, project: project, feature: feature} = ctx) do
    run =
      DeliveryFixtures.run_fixture(project, feature, %{
        initiator_account_id: ctx.owner_account.id
      })

    attempt = DeliveryFixtures.attempt_fixture(run, %{fence_token: 1})

    {:ok, %{feature: ready}} =
      DeliveryStore.commit(authority, project.id, [
        {:feature, {:transition_feature, feature, "ready_for_development", []}}
      ])

    {:ok, %{feature: developing}} =
      DeliveryStore.commit(authority, project.id, [
        {:feature, {:transition_feature, ready, "in_development", []}}
      ])

    {:ok, dispatched} =
      attempt
      |> RunAttempt.transition_changeset("dispatched", attempt.state_version)
      |> Repo.update()

    {:ok, started} =
      run |> AgentRun.transition_changeset("running", run.state_version) |> Repo.update()

    # The run's own history is how a feature's runs are found, exactly as the
    # start path writes it.
    DeliveryFixtures.activity_fixture(project, feature, %{
      run_id: run.id,
      attempt_id: dispatched.id,
      type: "run_started",
      payload: %{"branch" => run.branch}
    })

    Map.merge(ctx, %{
      run: started,
      attempt: dispatched,
      feature: Repo.get!(Feature, developing.id)
    })
  end

  # The same run after a non-retryable failure: stopped, visible, and waiting
  # for a person.
  defp stopped(%{authority: authority, project: project, run: run, attempt: attempt} = ctx) do
    {:ok, results} =
      Retry.handle_failure(
        authority,
        project.id,
        failed_event(run, attempt, "missing_configuration")
      )

    Map.merge(ctx, %{run: results.run, feature: results.feature})
  end

  defp fail(authority, project, {run, attempt}) do
    {:ok, results} =
      Retry.handle_failure(
        authority,
        project.id,
        failed_event(run, attempt, "transport_lost"),
        jitter: 0.0
      )

    {results.run, Map.get(results, :attempt, attempt)}
  end

  defp attempts(run) do
    RunAttempt
    |> where([a], a.run_id == ^run.id)
    |> order_by([a], asc: a.attempt_number)
    |> Repo.all()
  end

  defp current_attempts(run), do: run |> attempts() |> Enum.count(&RunAttempt.current?/1)

  defp entries(type) do
    ActivityEntry |> where([e], e.type == ^type) |> Repo.aggregate(:count)
  end

  defp failed_event(run, attempt, reason) do
    %{
      "type" => "event",
      "protocol_version" => WorkerProtocol.version(),
      "event_id" => "evt-#{System.unique_integer([:positive])}",
      "run_id" => run.id,
      "command_id" => "cmd-#{System.unique_integer([:positive])}",
      "attempt_number" => attempt.attempt_number,
      "fence_token" => attempt.fence_token,
      "sequence" => attempt.last_sequence + 1,
      "event_type" => "failed",
      "source" => "worker",
      "occurred_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "payload" => %{"reason" => reason}
    }
  end
end
