defmodule SddOrchestrator.Privacy.DeliveryDeviceTemporaryRetentionTest do
  @moduledoc """
  Task 6 proof: device-authoritative temporary execution-data expiry.

  The device half of the same lifecycle Task 1 proved for the hosted store, on
  the same 30-day window and the same eligibility rule: a terminal command and a
  resolved blocking question are released 30 days after their purpose ended,
  and never while the run that could still resume, retry, or reconcile from
  them is active.

  Two things make the device half its own proof rather than a repeat. The
  decision is made entirely inside the device authority — a device project has
  no hosted row at all, and this sweep must never create one — and the delete is
  a tombstone put, because the device delivery seam applies puts and nothing
  else. An unreachable worker is a pause, not a failure: its rules report zero
  and the rest of the pass still runs.
  """

  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Delivery.{AgentRun, BlockingQuestion, RunCommand}
  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.DeviceStore.Local
  alias SddOrchestrator.Privacy.Retention
  alias SddOrchestrator.Projects.Project

  @day 24 * 60 * 60
  @window 30 * @day

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "delivery-device-retention-#{System.unique_integer([:positive])}/store.dets"
      )

    start_supervised!({Local, path: path})
    on_exit(fn -> File.rm_rf!(Path.dirname(path)) end)

    {:ok, workspace} = Devices.establish_workspace()

    {:ok, project} =
      Devices.register_project(%{
        name: "Device delivery retention project",
        repository_fingerprint:
          "device-delivery-retention-fingerprint-#{System.unique_integer([:positive])}",
        status: "connected",
        idempotency_key: Ecto.UUID.generate()
      })

    %{project: project, workspace: workspace}
  end

  describe "device command expiry" do
    test "tombstones a terminal command at the 30-day boundary and keeps a day-29 command", %{
      project: project
    } do
      now = truncated_now()
      run = device_run!(project.id, "canceled")

      due = device_command!(project.id, run, at: DateTime.add(now, -@window, :second))

      just_inside =
        device_command!(project.id, run, at: DateTime.add(now, -@window + 1, :second))

      assert %{expired_device_delivery_commands: 1} = Retention.prune_all(now)

      assert tombstoned?(project.id, :command, due.id)
      assert {:ok, %RunCommand{}} = decoded(project.id, :command, just_inside.id)
    end

    test "keeps a command that has not reached a terminal state, however old it is", %{
      project: project
    } do
      now = truncated_now()
      run = device_run!(project.id, "completed")
      long_ago = DateTime.add(now, -10 * @window, :second)

      unfinished =
        for state <- ~w(pending claimed delivered) do
          device_command!(project.id, run, state: state, at: long_ago)
        end

      assert %{expired_device_delivery_commands: 0} = Retention.prune_all(now)

      for command <- unfinished do
        assert {:ok, %RunCommand{}} = decoded(project.id, :command, command.id)
      end
    end

    test "keeps an old terminal command while its own run is still active", %{project: project} do
      now = truncated_now()
      long_ago = DateTime.add(now, -10 * @window, :second)

      running = device_run!(project.id, "running")
      blocked = device_run!(project.id, "blocked")

      on_running = device_command!(project.id, running, at: long_ago)
      on_blocked = device_command!(project.id, blocked, at: long_ago)

      assert %{expired_device_delivery_commands: 0} = Retention.prune_all(now)

      assert {:ok, %RunCommand{}} = decoded(project.id, :command, on_running.id)
      assert {:ok, %RunCommand{}} = decoded(project.id, :command, on_blocked.id)
    end
  end

  describe "device checkpoint expiry" do
    test "tombstones a resolved question at the 30-day boundary and keeps a day-29 question", %{
      project: project
    } do
      now = truncated_now()
      run = device_run!(project.id, "completed")

      due = device_question!(project.id, run, at: DateTime.add(now, -@window, :second))

      just_inside =
        device_question!(project.id, run, at: DateTime.add(now, -@window + 1, :second))

      assert %{expired_device_delivery_checkpoints: 1} = Retention.prune_all(now)

      assert tombstoned?(project.id, :question, due.id)
      assert {:ok, %BlockingQuestion{}} = decoded(project.id, :question, just_inside.id)
    end

    test "never deletes an open question, however old it is", %{project: project} do
      now = truncated_now()
      run = device_run!(project.id, "canceled")

      open =
        device_question!(project.id, run,
          state: "open",
          at: DateTime.add(now, -10 * @window, :second)
        )

      assert %{expired_device_delivery_checkpoints: 0} = Retention.prune_all(now)

      assert {:ok, %BlockingQuestion{state: "open"}} = decoded(project.id, :question, open.id)
    end

    test "keeps an old resolved question while its own run is still active", %{project: project} do
      now = truncated_now()
      run = device_run!(project.id, "blocked")

      kept = device_question!(project.id, run, at: DateTime.add(now, -10 * @window, :second))

      assert %{expired_device_delivery_checkpoints: 0} = Retention.prune_all(now)

      assert {:ok, %BlockingQuestion{}} = decoded(project.id, :question, kept.id)
    end
  end

  describe "device deletion shape" do
    test "replaces the record with a bare tombstone instead of removing the key", %{
      project: project
    } do
      now = truncated_now()
      at = DateTime.add(now, -@window, :second)
      run = device_run!(project.id, "canceled")

      command = device_command!(project.id, run, at: at)
      question = device_question!(project.id, run, at: at)

      assert %{expired_device_delivery_commands: 1, expired_device_delivery_checkpoints: 1} =
               Retention.prune_all(now)

      # The key still exists — the delivery seam applies puts and nothing else —
      # and what it now holds is only the fact that this is no longer a command
      # or a question. No operation, result, checkpoint, branch, or workspace
      # path survives, and every decode treats the tombstone as absent.
      assert {:ok, %{"deleted" => true} = command_value} =
               Devices.get_delivery(project.id, :command, command.id)

      assert {:ok, %{"deleted" => true} = question_value} =
               Devices.get_delivery(project.id, :question, question.id)

      assert Map.keys(command_value) == ["deleted"]
      assert Map.keys(question_value) == ["deleted"]
      assert RunCommand.from_value(command_value) == {:error, :invalid_command_value}
      assert BlockingQuestion.from_value(question_value) == {:error, :invalid_question_value}

      # The run itself is untouched: this rule expires the resume aid, not the
      # delivery history it belonged to.
      assert {:ok, %AgentRun{}} = decoded(project.id, :run, run.id)
    end

    test "decides eligibility inside the device authority, creating no hosted copy", %{
      project: project
    } do
      now = truncated_now()
      at = DateTime.add(now, -@window, :second)
      run = device_run!(project.id, "canceled")

      device_command!(project.id, run, at: at)
      device_question!(project.id, run, at: at)

      assert %{expired_device_delivery_commands: 1, expired_device_delivery_checkpoints: 1} =
               Retention.prune_all(now)

      # Nothing about this project was read from or written to the hosted store
      # to decide what to prune, so after a full sweep the hosted tables the
      # hosted half governs are still empty — including the project row itself,
      # which a device-authoritative project never has.
      assert Repo.aggregate(RunCommand, :count) == 0
      assert Repo.aggregate(BlockingQuestion, :count) == 0
      assert Repo.aggregate(AgentRun, :count) == 0
      assert Repo.aggregate(Project, :count) == 0
    end
  end

  describe "availability and idempotency" do
    test "an unreachable device store pauses only its own rules", %{project: project} do
      now = truncated_now()
      at = DateTime.add(now, -@window, :second)

      device_run = device_run!(project.id, "canceled")
      device_command!(project.id, device_run, at: at)
      device_question!(project.id, device_run, at: at)

      hosted = hosted_due_command!(now)

      stop_supervised!(Local)

      # The device rules report zero rather than raising, and the pass carries
      # on: the hosted half of the very same lifecycle still deletes its own
      # due row in the same call.
      assert %{
               expired_device_delivery_commands: 0,
               expired_device_delivery_checkpoints: 0,
               expired_delivery_commands: 1
             } = Retention.prune_all(now)

      refute Repo.get(RunCommand, hosted.id)
    end

    test "a second pass immediately after reports nothing left to remove", %{project: project} do
      now = truncated_now()
      at = DateTime.add(now, -@window, :second)
      run = device_run!(project.id, "canceled")

      device_command!(project.id, run, at: at)
      device_question!(project.id, run, at: at)

      assert %{expired_device_delivery_commands: 1, expired_device_delivery_checkpoints: 1} =
               Retention.prune_all(now)

      assert %{expired_device_delivery_commands: 0, expired_device_delivery_checkpoints: 0} =
               Retention.prune_all(now)
    end
  end

  defp truncated_now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  # Written straight through the delivery seam rather than through the delivery
  # store's own operations, because every one of those writes its instants from
  # the live clock and this rule is measured against those instants.
  defp device_run!(project_id, state) do
    unique = System.unique_integer([:positive])

    run = %AgentRun{
      id: Ecto.UUID.generate(),
      project_id: project_id,
      feature_id: Ecto.UUID.generate(),
      starting_revision_id: "rev-#{unique}",
      starting_revision_digest: String.duplicate("a", 64),
      effective_revision_id: "rev-#{unique}",
      effective_revision_digest: String.duplicate("a", 64),
      approved_slice: "slice-19",
      branch: "sdd/device-feature-#{unique}",
      state: state,
      current_attempt_number: 1,
      state_version: 1
    }

    put!(project_id, :run, run.id, AgentRun.to_value(run))

    run
  end

  # `due_at` is the instant the device value shape carries: the last time this
  # instruction was scheduled for delivery, which for a terminal command is the
  # delivery it answered. The device shape has no `acknowledged_at` or
  # `updated_at` of its own.
  defp device_command!(project_id, run, attrs) do
    attrs = Map.new(attrs)

    command = %RunCommand{
      id: Ecto.UUID.generate(),
      project_id: project_id,
      run_id: run.id,
      operation: "cancel",
      expected_state_version: 1,
      due_at: Map.fetch!(attrs, :at),
      state: Map.get(attrs, :state, "acknowledged"),
      delivery_count: 1,
      result: %{"outcome" => "ok"},
      failure_code: Map.get(attrs, :failure_code)
    }

    put!(project_id, :command, command.id, RunCommand.to_value(command))

    command
  end

  # `asked_at` is the instant the device value shape carries; a resolution can
  # only have happened at or after it, so measuring from it never keeps the
  # record longer than the hosted `updated_at` rule would.
  defp device_question!(project_id, run, attrs) do
    attrs = Map.new(attrs)
    state = Map.get(attrs, :state, "answered")

    question = %BlockingQuestion{
      id: Ecto.UUID.generate(),
      project_id: project_id,
      feature_id: run.feature_id,
      run_id: run.id,
      question: "Should the resume aid outlive the run it belongs to?",
      context: "The answer decides the retention window.",
      state: state,
      checkpoint: %{"step" => "verification", "notes" => "resume from the failing check"},
      branch: run.branch,
      workspace_path: "/Users/developer/work/#{run.id}",
      asked_at: Map.fetch!(attrs, :at),
      resulting_revision_id: if(state == "answered", do: "rev-answer-1"),
      state_version: if(state == "open", do: 1, else: 2)
    }

    put!(project_id, :question, question.id, BlockingQuestion.to_value(question))

    question
  end

  defp put!(project_id, kind, id, value) do
    {:ok, _applied} = Devices.commit_delivery(project_id, [{:put, kind, id, value, nil}])
    :ok
  end

  defp decoded(project_id, kind, id) do
    {:ok, value} = Devices.get_delivery(project_id, kind, id)

    case kind do
      :command -> RunCommand.from_value(value)
      :question -> BlockingQuestion.from_value(value)
      :run -> AgentRun.from_value(value)
    end
  end

  defp tombstoned?(project_id, kind, id),
    do: Devices.get_delivery(project_id, kind, id) == {:ok, %{"deleted" => true}}

  # One hosted terminal command that Task 1's rule is due to delete, so the
  # unreachable-device proof can show the pass continuing rather than only that
  # it did not raise.
  defp hosted_due_command!(now) do
    context = DeliveryFixtures.delivery_project_fixture()
    feature = DeliveryFixtures.feature_fixture(context.project, context.account)

    run =
      context.project
      |> DeliveryFixtures.run_fixture(feature)
      |> ended_run()

    at = usec(DateTime.add(now, -@window, :second))

    Repo.insert!(%RunCommand{
      id: Ecto.UUID.generate(),
      project_id: context.project.id,
      run_id: run.id,
      operation: "cancel",
      expected_state_version: 1,
      due_at: at,
      state: "acknowledged",
      delivery_count: 1,
      delivered_at: at,
      acknowledged_at: at,
      result: %{"outcome" => "ok"},
      inserted_at: at,
      updated_at: at
    })
  end

  # `"canceled"` is reachable from `"pending"` in one legal move.
  defp ended_run(run) do
    run
    |> AgentRun.transition_changeset("canceled", run.state_version)
    |> Repo.update!()
  end

  # `DateTime.truncate/2` only ever lowers precision, so it cannot widen a
  # second-precision fixture time into the microsecond precision the hosted
  # command columns declare. Adding zero microseconds does.
  defp usec(value), do: DateTime.add(value, 0, :microsecond)
end
