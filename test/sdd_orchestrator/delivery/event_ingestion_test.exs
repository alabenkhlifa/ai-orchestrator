defmodule SddOrchestrator.Delivery.EventIngestionTest do
  @moduledoc """
  Proof for normalized progress and run status (Task 21).

  A worker is the least trusted thing in the system: it may be superseded, it
  may replay, it may reconnect mid-stream, and its provider's event shape is
  outside this product's control. These tests pin that none of that can move a
  run — only an event that proves it belongs to the current attempt, in order,
  in the approved schema, does.
  """
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Delivery.{
    ActivityEntry,
    AgentRun,
    DeliveryStore,
    EventIngestion,
    RunAttempt,
    RunStatus,
    WorkerProtocol
  }

  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.Repo

  setup do
    context = DeliveryFixtures.delivery_project_fixture()
    feature = DeliveryFixtures.feature_fixture(context.project, context.account)
    run = DeliveryFixtures.run_fixture(context.project, feature)
    pending = DeliveryFixtures.attempt_fixture(run, %{fence_token: 3})

    # The dispatcher records delivery before a worker can report on an attempt,
    # so the ingestion path is exercised from the state it really sees.
    {:ok, attempt} =
      pending
      |> SddOrchestrator.Delivery.RunAttempt.transition_changeset(
        "dispatched",
        pending.state_version
      )
      |> Repo.update()

    %{
      authority: context.workspace,
      project: context.project,
      feature: feature,
      run: run,
      attempt: attempt
    }
  end

  describe "accepting a valid event" do
    test "appends normalized activity and advances the attempt sequence", %{
      authority: authority,
      project: project,
      run: run,
      attempt: attempt
    } do
      assert {:ok, results} =
               EventIngestion.ingest(authority, project.id, event(run, attempt, sequence: 1))

      assert results.activity.type == "progress"
      assert results.activity.actor_kind == "agent"
      refute results.activity.actor_account_id
      assert results.activity.run_id == run.id
      assert results.activity.attempt_id == attempt.id
      assert results.attempt.last_sequence == 1
    end

    test "moves a pending run to running on its first accepted event", %{
      authority: authority,
      project: project,
      run: run,
      attempt: attempt
    } do
      {:ok, results} =
        EventIngestion.ingest(authority, project.id, event(run, attempt, sequence: 1))

      assert results.run.state == "running"
      assert Repo.get!(AgentRun, run.id).state == "running"

      # The attempt keeps the state the dispatcher gave it; progress moves the
      # run, not the attempt's own lifecycle.
      assert Repo.get!(RunAttempt, attempt.id).state == "dispatched"
    end

    test "accepts a contiguous stream in order", %{
      authority: authority,
      project: project,
      run: run,
      attempt: attempt
    } do
      Enum.reduce(1..3, {run, attempt}, fn sequence, {current_run, current_attempt} ->
        {:ok, results} =
          EventIngestion.ingest(
            authority,
            project.id,
            event(current_run, current_attempt, sequence: sequence)
          )

        {Map.get(results, :run, current_run), results.attempt}
      end)

      assert Repo.get!(RunAttempt, attempt.id).last_sequence == 3
      assert Repo.aggregate(ActivityEntry, :count) == 3
    end

    test "carries a summary but never the provider's own event shape", %{
      authority: authority,
      project: project,
      run: run,
      attempt: attempt
    } do
      envelope =
        event(run, attempt,
          sequence: 1,
          payload: %{"summary" => "Ran the tests", "provider_shape" => "ignored"}
        )

      {:ok, results} = EventIngestion.ingest(authority, project.id, envelope)

      assert results.activity.payload["summary"] == "Ran the tests"
      assert results.activity.payload["event_type"] == "progress"
      refute Map.has_key?(results.activity.payload, "provider_shape")
      refute Map.has_key?(results.activity.payload, "payload")
    end
  end

  describe "rejecting what must not move a run" do
    test "a superseded worker's fence cannot move anything", %{
      authority: authority,
      project: project,
      run: run,
      attempt: attempt
    } do
      envelope = event(run, attempt, sequence: 1, fence_token: 2)

      assert {:error, :stale_fence} = EventIngestion.ingest(authority, project.id, envelope)
      refute EventIngestion.acceptable?(authority, project.id, envelope)

      assert Repo.aggregate(ActivityEntry, :count) == 0
      assert Repo.get!(AgentRun, run.id).state == "pending"
      assert Repo.get!(RunAttempt, attempt.id).last_sequence == 0
    end

    test "a replayed sequence is a duplicate, not a second entry", %{
      authority: authority,
      project: project,
      run: run,
      attempt: attempt
    } do
      {:ok, results} =
        EventIngestion.ingest(authority, project.id, event(run, attempt, sequence: 1))

      assert {:error, :duplicate_event} =
               EventIngestion.ingest(
                 authority,
                 project.id,
                 event(run, results.attempt, sequence: 1)
               )

      assert Repo.aggregate(ActivityEntry, :count) == 1
    end

    test "an out-of-order event is refused", %{
      authority: authority,
      project: project,
      run: run,
      attempt: attempt
    } do
      {:ok, results} =
        EventIngestion.ingest(authority, project.id, event(run, attempt, sequence: 5))

      assert {:error, :stale_sequence} =
               EventIngestion.ingest(
                 authority,
                 project.id,
                 event(run, results.attempt, sequence: 4)
               )

      assert Repo.get!(RunAttempt, attempt.id).last_sequence == 5
    end

    test "an envelope failing the protocol schema never reaches storage", %{
      authority: authority,
      project: project,
      run: run,
      attempt: attempt
    } do
      malformed = run |> event(attempt, sequence: 1) |> Map.delete("occurred_at")
      unknown_field = run |> event(attempt, sequence: 1) |> Map.put("extra", "nope")
      bad_version = run |> event(attempt, sequence: 1) |> Map.put("protocol_version", 999)

      for envelope <- [malformed, unknown_field, bad_version] do
        assert {:error, _reason} = EventIngestion.ingest(authority, project.id, envelope)
      end

      assert Repo.aggregate(ActivityEntry, :count) == 0
    end

    test "an oversized payload is refused", %{
      authority: authority,
      project: project,
      run: run,
      attempt: attempt
    } do
      envelope =
        event(run, attempt,
          sequence: 1,
          payload: %{"summary" => String.duplicate("x", 200_000)}
        )

      assert {:error, _reason} = EventIngestion.ingest(authority, project.id, envelope)
      assert Repo.aggregate(ActivityEntry, :count) == 0
    end

    test "a credential-shaped field is refused rather than redacted later", %{
      authority: authority,
      project: project,
      run: run,
      attempt: attempt
    } do
      envelope =
        event(run, attempt, sequence: 1, payload: %{"api_key" => "sk-abcdefghijklmnop"})

      assert {:error, _reason} = EventIngestion.ingest(authority, project.id, envelope)
      assert Repo.aggregate(ActivityEntry, :count) == 0
    end

    test "an event for an unknown run is refused", %{
      authority: authority,
      project: project,
      run: run,
      attempt: attempt
    } do
      envelope =
        run |> event(attempt, sequence: 1) |> Map.put("run_id", Ecto.UUID.generate())

      assert {:error, :unknown_run} = EventIngestion.ingest(authority, project.id, envelope)
    end

    test "an event for a run with no current attempt is refused", %{
      authority: authority,
      project: project,
      run: run,
      attempt: attempt
    } do
      {:ok, _ended} =
        DeliveryStore.commit(authority, project.id, [
          {:ended, {:transition_attempt, attempt, "superseded"}}
        ])

      assert {:error, :no_current_attempt} =
               EventIngestion.ingest(authority, project.id, event(run, attempt, sequence: 1))
    end

    test "an event type this task does not own is refused rather than half-applied", %{
      authority: authority,
      project: project,
      run: run,
      attempt: attempt
    } do
      for type <- WorkerProtocol.event_types() -- EventIngestion.handled_event_types() do
        envelope = run |> event(attempt, sequence: 1) |> Map.put("event_type", type)

        assert {:error, :unsupported_event} =
                 EventIngestion.ingest(authority, project.id, envelope)
      end

      assert Repo.aggregate(ActivityEntry, :count) == 0
    end

    test "an event for another project's run is refused", %{
      authority: authority,
      run: run,
      attempt: attempt
    } do
      other = DeliveryFixtures.delivery_project_fixture()

      assert {:error, :unknown_run} =
               EventIngestion.ingest(
                 authority,
                 other.project.id,
                 event(run, attempt, sequence: 1)
               )
    end
  end

  describe "visible status seam" do
    test "a live run shows no status, so the card stays clean", %{run: run} do
      assert RunStatus.for_run(run) == "none"
      assert RunStatus.live?(run)
      refute RunStatus.reason(run)
    end

    test "blocked and failed are statuses, never columns", %{run: run} do
      blocked = %{run | state: "blocked"}
      failed = %{run | state: "failed", failure_reason: "agent_process_exit"}

      assert RunStatus.for_run(blocked) == "blocked"
      assert RunStatus.label("blocked") == "Blocked"
      assert RunStatus.for_run(failed) == "failed"
      assert RunStatus.reason(failed) == "agent_process_exit"
      assert RunStatus.live?(blocked)
      refute RunStatus.live?(failed)
    end

    test "a finished run stops decorating the card", %{run: run} do
      for state <- ~w(completed canceled) do
        assert RunStatus.for_run(%{run | state: state}) == "none"
        refute RunStatus.live?(%{run | state: state})
      end

      assert RunStatus.for_run(nil) == "none"
      refute RunStatus.live?(nil)
    end
  end

  defp event(run, attempt, opts) do
    %{
      "type" => "event",
      "protocol_version" => WorkerProtocol.version(),
      "event_id" => "evt-#{System.unique_integer([:positive])}",
      "run_id" => run.id,
      "command_id" => "cmd-#{System.unique_integer([:positive])}",
      "attempt_number" => attempt.attempt_number,
      "fence_token" => Keyword.get(opts, :fence_token, attempt.fence_token),
      "sequence" => Keyword.fetch!(opts, :sequence),
      "event_type" => "progress",
      "source" => "agent",
      "occurred_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "payload" => Keyword.get(opts, :payload, %{"summary" => "Working"})
    }
  end
end
