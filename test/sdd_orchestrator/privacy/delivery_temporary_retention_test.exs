defmodule SddOrchestrator.Privacy.DeliveryTemporaryRetentionTest do
  @moduledoc """
  Task 1 proof: hosted temporary execution-data expiry.

  A `RunCommand` and a `BlockingQuestion` are the two rows guided delivery keeps
  purely so work can be recovered — an instruction a dispatcher can redeliver,
  and the checkpoint, branch, and worker-local workspace path a later attempt
  resumes accepted work from. Once the run that could use them is no longer
  active and 30 days have passed since that purpose ended, both rows are
  deleted from the hosted store.

  Age alone never releases either row: a command or question belonging to a run
  that is still `"running"` or `"blocked"` is current recovery material. And the
  delete removes only the resume aid — the participant-visible question and its
  answer live in `activity_entries` as `"question_asked"` and
  `"question_answered"`, and survive untouched.
  """

  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Delivery.{ActivityEntry, AgentRun, BlockingQuestion, RunCommand}
  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.Privacy.Retention

  @day 24 * 60 * 60
  @window 30 * @day

  setup do
    context = DeliveryFixtures.delivery_project_fixture()
    feature = DeliveryFixtures.feature_fixture(context.project, context.account)

    %{project: context.project, account: context.account, feature: feature}
  end

  describe "inactive command expiry" do
    test "deletes an acknowledged command at the 30-day boundary and keeps a day-29 command",
         context do
      now = truncated_now()
      run = ended_run(context)

      due = command_fixture(context, run, at: DateTime.add(now, -@window, :second))
      just_inside = command_fixture(context, run, at: DateTime.add(now, -@window + 1, :second))

      assert %{expired_delivery_commands: 1} = Retention.prune_all(now)

      refute Repo.get(RunCommand, due.id)
      assert Repo.get(RunCommand, just_inside.id)
    end

    test "deletes a failed command at the 30-day boundary", context do
      now = truncated_now()
      run = ended_run(context)

      due =
        command_fixture(context, run,
          state: "failed",
          failure_code: "worker_unreachable",
          at: DateTime.add(now, -@window, :second)
        )

      assert %{expired_delivery_commands: 1} = Retention.prune_all(now)

      refute Repo.get(RunCommand, due.id)
    end

    test "measures a terminal command that recorded no acknowledgement by its own updated_at",
         context do
      now = truncated_now()
      run = ended_run(context)

      # `COALESCE(acknowledged_at, updated_at)`: the fallback is what stops a
      # terminal row without an acknowledgement time from being retained forever.
      due =
        command_fixture(context, run,
          acknowledged_at: nil,
          at: DateTime.add(now, -@window, :second)
        )

      just_inside =
        command_fixture(context, run,
          acknowledged_at: nil,
          at: DateTime.add(now, -@window + 1, :second)
        )

      assert %{expired_delivery_commands: 1} = Retention.prune_all(now)

      refute Repo.get(RunCommand, due.id)
      assert Repo.get(RunCommand, just_inside.id)
    end

    test "keeps a pending, claimed, or delivered command however old it is", context do
      now = truncated_now()
      run = ended_run(context)
      long_ago = DateTime.add(now, -10 * @window, :second)

      unfinished =
        for state <- ~w(pending claimed delivered) do
          command_fixture(context, run, state: state, acknowledged_at: nil, at: long_ago)
        end

      assert %{expired_delivery_commands: 0} = Retention.prune_all(now)

      for command <- unfinished, do: assert(Repo.get(RunCommand, command.id))
    end

    test "keeps an old terminal command while its run is still running", context do
      now = truncated_now()
      run = context |> new_run() |> transition!("running")

      kept = command_fixture(context, run, at: DateTime.add(now, -10 * @window, :second))

      assert %{expired_delivery_commands: 0} = Retention.prune_all(now)

      assert Repo.get(RunCommand, kept.id)
    end

    test "keeps an old terminal command while its run is blocked", context do
      now = truncated_now()

      run =
        context |> new_run() |> transition!("running") |> transition!("blocked")

      kept = command_fixture(context, run, at: DateTime.add(now, -10 * @window, :second))

      assert %{expired_delivery_commands: 0} = Retention.prune_all(now)

      assert Repo.get(RunCommand, kept.id)
    end
  end

  describe "resolved checkpoint expiry" do
    test "deletes an answered question at the 30-day boundary and keeps a day-29 question",
         context do
      now = truncated_now()

      due =
        question_fixture(context, ended_run(context), at: DateTime.add(now, -@window, :second))

      just_inside =
        question_fixture(context, ended_run(context),
          at: DateTime.add(now, -@window + 1, :second)
        )

      assert %{expired_delivery_checkpoints: 1} = Retention.prune_all(now)

      refute Repo.get(BlockingQuestion, due.id)
      assert Repo.get(BlockingQuestion, just_inside.id)
    end

    test "deletes a superseded question at the 30-day boundary", context do
      now = truncated_now()

      due =
        question_fixture(context, ended_run(context),
          state: "superseded",
          at: DateTime.add(now, -@window, :second)
        )

      assert %{expired_delivery_checkpoints: 1} = Retention.prune_all(now)

      refute Repo.get(BlockingQuestion, due.id)
    end

    test "never deletes an open question, however old it is", context do
      now = truncated_now()

      open =
        question_fixture(context, ended_run(context),
          state: "open",
          at: DateTime.add(now, -10 * @window, :second)
        )

      assert %{expired_delivery_checkpoints: 0} = Retention.prune_all(now)

      assert Repo.get(BlockingQuestion, open.id)
    end

    test "keeps an old resolved question while its run is still running or blocked", context do
      now = truncated_now()
      long_ago = DateTime.add(now, -10 * @window, :second)

      running = context |> new_run() |> transition!("running")
      blocked = context |> new_run() |> transition!("running") |> transition!("blocked")

      on_running = question_fixture(context, running, at: long_ago)
      on_blocked = question_fixture(context, blocked, at: long_ago)

      assert %{expired_delivery_checkpoints: 0} = Retention.prune_all(now)

      assert Repo.get(BlockingQuestion, on_running.id)
      assert Repo.get(BlockingQuestion, on_blocked.id)
    end

    test "leaves the participant-visible question and answer in activity untouched", context do
      now = truncated_now()

      asked =
        DeliveryFixtures.activity_fixture(context.project, context.feature, %{
          actor_kind: "agent",
          type: "question_asked",
          payload: %{"question" => "Which retention window applies to the resume aid?"}
        })

      answered =
        DeliveryFixtures.activity_fixture(context.project, context.feature, %{
          actor_kind: "participant",
          actor_account_id: context.account.id,
          type: "question_answered",
          payload: %{"answer" => "Thirty days after the run ends."}
        })

      due =
        question_fixture(context, ended_run(context), at: DateTime.add(now, -@window, :second))

      assert %{expired_delivery_checkpoints: 1} = Retention.prune_all(now)

      refute Repo.get(BlockingQuestion, due.id)

      assert Repo.get(ActivityEntry, asked.id) == asked
      assert Repo.get(ActivityEntry, answered.id) == answered
    end
  end

  describe "idempotency" do
    test "a second pass immediately after reports nothing left to remove", context do
      now = truncated_now()
      at = DateTime.add(now, -@window, :second)
      run = ended_run(context)

      command_fixture(context, run, at: at)
      question_fixture(context, run, at: at)

      assert %{expired_delivery_commands: 1, expired_delivery_checkpoints: 1} =
               Retention.prune_all(now)

      assert %{expired_delivery_commands: 0, expired_delivery_checkpoints: 0} =
               Retention.prune_all(now)
    end
  end

  defp truncated_now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp new_run(context),
    do: DeliveryFixtures.run_fixture(context.project, context.feature)

  # A run that has ended, so its commands and resolved questions are released by
  # age alone. `"canceled"` is reachable from `"pending"` in one legal move.
  defp ended_run(context), do: context |> new_run() |> transition!("canceled")

  defp transition!(run, to) do
    run
    |> AgentRun.transition_changeset(to, run.state_version)
    |> Repo.update!()
  end

  # Inserted directly rather than through the enqueue and acknowledge
  # changesets, because the rule is measured against timestamps those
  # changesets always write from the live clock.
  defp command_fixture(context, run, attrs) do
    attrs = Map.new(attrs)
    state = Map.get(attrs, :state, "acknowledged")
    at = attrs |> Map.fetch!(:at) |> usec()
    acknowledged_at = attrs |> Map.get(:acknowledged_at, at) |> maybe_usec()

    Repo.insert!(%RunCommand{
      id: Ecto.UUID.generate(),
      project_id: context.project.id,
      run_id: run.id,
      operation: "cancel",
      expected_state_version: 1,
      due_at: at,
      state: state,
      claimed_by: if(state == "claimed", do: "dispatcher-1"),
      claim_expires_at: if(state == "claimed", do: at),
      delivery_count: 1,
      delivered_at: at,
      acknowledged_at: acknowledged_at,
      result: %{"outcome" => "ok"},
      failure_code: Map.get(attrs, :failure_code),
      inserted_at: at,
      updated_at: at
    })
  end

  # `updated_at` is the resolution time: resolving is the transition that bumps
  # `state_version`, and there is deliberately no `resolved_at` column.
  defp question_fixture(context, run, attrs) do
    attrs = Map.new(attrs)
    state = Map.get(attrs, :state, "answered")
    at = attrs |> Map.fetch!(:at) |> DateTime.truncate(:second)

    Repo.insert!(%BlockingQuestion{
      id: Ecto.UUID.generate(),
      project_id: context.project.id,
      feature_id: context.feature.id,
      run_id: run.id,
      question: "Should the resume aid outlive the run it belongs to?",
      context: "The answer decides the retention window.",
      state: state,
      checkpoint: %{"step" => "verification", "notes" => "resume from the failing check"},
      branch: run.branch,
      workspace_path: "/Users/developer/work/#{run.id}",
      asked_at: usec(at),
      resulting_revision_id: if(state == "answered", do: "rev-answer-1"),
      state_version: if(state == "open", do: 1, else: 2),
      inserted_at: at,
      updated_at: at
    })
  end

  defp maybe_usec(nil), do: nil
  defp maybe_usec(value), do: usec(value)

  # `DateTime.truncate/2` only ever lowers precision, so it cannot widen a
  # second-precision fixture time into the microsecond precision the command
  # columns declare. Adding zero microseconds does.
  defp usec(value), do: DateTime.add(value, 0, :microsecond)
end
