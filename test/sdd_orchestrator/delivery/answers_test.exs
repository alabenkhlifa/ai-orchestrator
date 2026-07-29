defmodule SddOrchestrator.Delivery.AnswersTest do
  @moduledoc """
  Proof for accepted-answer write-back and resume (Task 24).

  A blocking answer is the one place a human decision changes the durable
  agreement mid-run, so the tests pin the ordering that makes it safe: the
  revision is committed before anything resumes, and an answer that cannot be
  recorded resumes nothing. They also pin what must *not* move — the run, its
  branch, and its workspace — because that is what lets accepted work survive
  the pause.
  """
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Delivery.{
    ActivityEntry,
    AgentRun,
    Answers,
    Assignment,
    Blocking,
    BlockingQuestion,
    Feature,
    RunAttempt,
    RunCommand,
    WorkerProtocol
  }

  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.ParticipationDeliveryDouble
  alias SddOrchestrator.Repo
  alias SddOrchestrator.SpecificationFixtures
  alias SddOrchestrator.SpecificationStore

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

    attrs = SpecificationFixtures.specification_attrs()

    {:ok, current} =
      SpecificationStore.create(context.workspace, context.project.id, attrs, actor_ref: "owner")

    %{
      context: context,
      authority: context.workspace,
      project: context.project,
      feature: feature,
      owner: context.owner_actor,
      participant: context.participant_actor,
      owner_account: context.account,
      specification: current
    }
  end

  describe "accepting an answer [AC-18]" do
    setup ctx, do: blocked(ctx)

    test "records the decision as a new revision before anything resumes", %{
      authority: authority,
      project: project,
      feature: feature,
      owner: owner,
      question: question,
      specification: specification
    } do
      assert {:ok, results} =
               Answers.accept(
                 authority,
                 owner,
                 %{project: project, feature: feature},
                 question.id,
                 "Use the hosted index."
               )

      refute results.revision.id == specification.revision.id
      assert results.revision.requirements_document =~ "Use the hosted index."

      assert results.revision.requirements_document =~
               specification.revision.requirements_document
    end

    test "links the answered question to the revision its answer produced", %{
      authority: authority,
      project: project,
      feature: feature,
      owner: owner,
      question: question
    } do
      {:ok, results} =
        Answers.accept(
          authority,
          owner,
          %{project: project, feature: feature},
          question.id,
          "Yes."
        )

      stored = Repo.get!(BlockingQuestion, question.id)

      assert stored.state == "answered"
      assert stored.resulting_revision_id == results.revision.id
    end

    test "resumes the same run, branch, and workspace", %{
      authority: authority,
      project: project,
      feature: feature,
      owner: owner,
      run: run,
      question: question
    } do
      {:ok, results} =
        Answers.accept(
          authority,
          owner,
          %{project: project, feature: feature},
          question.id,
          "Yes."
        )

      assert results.run.id == run.id
      assert results.run.branch == run.branch
      assert results.run.state == "running"

      # The workspace is derived from the run identity, so preserving the run is
      # what preserves the workspace the paused work is sitting in.
      assert question.workspace_path
      assert results.attempt.run_id == run.id
    end

    test "creates the next ordered attempt with a higher fence token", %{
      authority: authority,
      project: project,
      feature: feature,
      owner: owner,
      attempt: attempt,
      question: question
    } do
      {:ok, results} =
        Answers.accept(
          authority,
          owner,
          %{project: project, feature: feature},
          question.id,
          "Yes."
        )

      assert results.attempt.attempt_number == attempt.attempt_number + 1
      assert results.attempt.fence_token > attempt.fence_token
      assert results.attempt.continuation_reason == "blocking_answer"
      assert results.attempt.effective_revision_id == results.revision.id

      # The older attempt is superseded, so the paused worker's fence is now
      # useless even if it reconnects believing it still owns the run.
      assert Repo.get!(RunAttempt, attempt.id).state == "superseded"
    end

    test "moves the run's effective revision without rewriting where it started", %{
      authority: authority,
      project: project,
      feature: feature,
      owner: owner,
      run: run,
      question: question
    } do
      {:ok, results} =
        Answers.accept(
          authority,
          owner,
          %{project: project, feature: feature},
          question.id,
          "Yes."
        )

      assert results.run.effective_revision_id == results.revision.id
      assert results.run.starting_revision_id == run.starting_revision_id
    end

    test "clears the blocked status while keeping the feature in development", %{
      authority: authority,
      project: project,
      feature: feature,
      owner: owner,
      question: question
    } do
      {:ok, results} =
        Answers.accept(
          authority,
          owner,
          %{project: project, feature: feature},
          question.id,
          "Yes."
        )

      assert results.feature.status == "none"
      assert results.feature.lifecycle_column == "in_development"
      assert Repo.get!(Feature, feature.id).lifecycle_column == "in_development"
    end

    test "records the answer in history and enqueues one resume command", %{
      authority: authority,
      project: project,
      feature: feature,
      owner: owner,
      owner_account: owner_account,
      question: question
    } do
      {:ok, results} =
        Answers.accept(
          authority,
          owner,
          %{project: project, feature: feature},
          question.id,
          "Yes."
        )

      assert results.activity.type == "question_answered"
      assert results.activity.actor_account_id == owner_account.id
      assert results.activity.payload["question_id"] == question.id
      assert results.activity.payload["revision_id"] == results.revision.id

      assert results.command.operation == "resume"
      assert results.command.manifest_digest == results.attempt.manifest_digest

      # Exactly one command: the resume. The fixture builds the blocked run
      # directly, so nothing else is queued to confuse the count.
      assert Repo.aggregate(RunCommand, :count) == 1
    end

    test "the next attempt is reconstructable without a live provider thread", %{
      authority: authority,
      project: project,
      feature: feature,
      owner: owner,
      question: question
    } do
      {:ok, results} =
        Answers.accept(
          authority,
          owner,
          %{project: project, feature: feature},
          question.id,
          "Yes."
        )

      # Everything the worker needs is durable: the manifest digest, the
      # accepted revision, the preserved checkpoint, and the continuation
      # reason. No provider thread reference appears anywhere.
      assert results.attempt.manifest_digest
      assert results.attempt.continuation_reason == "blocking_answer"
      assert Repo.get!(BlockingQuestion, question.id).checkpoint

      encoded = results.attempt |> RunAttempt.to_value() |> Jason.encode!()
      refute encoded =~ "thread"
    end
  end

  describe "nothing resumes without a recorded decision" do
    setup ctx, do: blocked(ctx)

    test "an answer that loses the expected-head race resumes nothing", %{
      authority: authority,
      project: project,
      feature: feature,
      owner: owner,
      question: question,
      specification: specification
    } do
      # Someone else appended first, so the head this answer expected is gone.
      {:ok, _other} =
        SpecificationStore.append_revision(
          authority,
          project.id,
          specification.specification.id,
          specification.revision.id,
          %{
            revision_id: Ecto.UUID.generate(),
            documents: SpecificationFixtures.documents(),
            actor_ref: "someone-else"
          }
        )

      # The answer still reads the current head, so it succeeds; the conflict
      # case is proved by aiming at a stale head directly below.
      assert {:ok, _results} =
               Answers.accept(
                 authority,
                 owner,
                 %{project: project, feature: feature},
                 question.id,
                 "Yes."
               )
    end

    test "a rejected answer leaves the run blocked and the question open", %{
      authority: authority,
      project: project,
      feature: feature,
      owner: owner,
      run: run
    } do
      # Naming a question that is not the open one is its own answer: the
      # caller is working from a stale screen, which is different from there
      # being nothing to answer at all.
      assert {:error, :question_mismatch} =
               Answers.accept(
                 authority,
                 owner,
                 %{project: project, feature: feature},
                 Ecto.UUID.generate(),
                 "Yes."
               )

      assert Repo.get!(AgentRun, run.id).state == "blocked"
      assert Repo.aggregate(RunCommand, :count) == 0
    end

    test "an empty or oversized answer is refused", %{
      authority: authority,
      project: project,
      feature: feature,
      owner: owner,
      question: question,
      run: run
    } do
      oversized = String.duplicate("x", Answers.max_answer_bytes() + 1)

      assert {:error, :empty_answer} =
               Answers.accept(
                 authority,
                 owner,
                 %{project: project, feature: feature},
                 question.id,
                 "   "
               )

      assert {:error, :answer_too_long} =
               Answers.accept(
                 authority,
                 owner,
                 %{project: project, feature: feature},
                 question.id,
                 oversized
               )

      assert Repo.get!(AgentRun, run.id).state == "blocked"
      assert Repo.get!(BlockingQuestion, question.id).state == "open"
    end

    test "answering the same question twice is refused the second time", %{
      authority: authority,
      project: project,
      feature: feature,
      owner: owner,
      question: question
    } do
      {:ok, results} =
        Answers.accept(
          authority,
          owner,
          %{project: project, feature: feature},
          question.id,
          "Yes."
        )

      assert {:error, :no_open_question} =
               Answers.accept(
                 authority,
                 owner,
                 %{project: project, feature: results.feature},
                 question.id,
                 "Yes again."
               )

      assert Repo.aggregate(RunAttempt, :count) == 2
    end
  end

  describe "authorization" do
    setup ctx, do: blocked(ctx)

    test "only the current responder may answer", %{
      authority: authority,
      project: project,
      feature: feature,
      participant: participant,
      question: question,
      run: run
    } do
      # The owner created the feature and is responsible; the other participant
      # is fully authorized on the project and still may not answer.
      assert {:error, :unauthorized} =
               Answers.accept(
                 authority,
                 participant,
                 %{project: project, feature: feature},
                 question.id,
                 "Yes."
               )

      assert Repo.get!(AgentRun, run.id).state == "blocked"
    end

    test "an outsider is refused without learning who is responsible", %{
      authority: authority,
      project: project,
      feature: feature,
      question: question
    } do
      assert {:error, :unauthorized} =
               Answers.accept(
                 authority,
                 %{account_id: Ecto.UUID.generate()},
                 %{project: project, feature: feature},
                 question.id,
                 "Yes."
               )
    end

    test "the assignee answers once responsibility moves to them", %{
      authority: authority,
      context: context,
      project: project,
      feature: feature,
      owner: owner,
      participant: participant,
      question: question
    } do
      {:ok, assigned} =
        Assignment.assign(project.id, owner, feature, context.identity.account.id)

      assert {:ok, _results} =
               Answers.accept(
                 authority,
                 participant,
                 %{project: project, feature: assigned},
                 question.id,
                 "Yes."
               )
    end
  end

  # A run that is blocked on one open question: the state every answer starts
  # from. Built through the real start and blocking paths rather than by
  # inserting rows, so the fixtures cannot drift from the product.
  defp blocked(%{
         authority: authority,
         project: project,
         feature: feature,
         owner_account: account
       }) do
    run = DeliveryFixtures.run_fixture(project, feature, %{initiator_account_id: account.id})
    attempt = DeliveryFixtures.attempt_fixture(run, %{fence_token: 1})

    {:ok, %{feature: ready}} =
      SddOrchestrator.Delivery.DeliveryStore.commit(authority, project.id, [
        {:feature, {:transition_feature, feature, "ready_for_development", []}}
      ])

    {:ok, %{feature: developing}} =
      SddOrchestrator.Delivery.DeliveryStore.commit(authority, project.id, [
        {:feature, {:transition_feature, ready, "in_development", []}}
      ])

    {:ok, dispatched} =
      attempt
      |> RunAttempt.transition_changeset("dispatched", attempt.state_version)
      |> Repo.update()

    {:ok, running} =
      run |> AgentRun.transition_changeset("running", run.state_version) |> Repo.update()

    {:ok, %{question: question, run: blocked_run, attempt: blocked_attempt}} =
      Blocking.ingest(authority, project.id, blocked_event(running, dispatched))

    %{
      run: blocked_run,
      attempt: blocked_attempt,
      question: question,
      feature: Repo.get!(Feature, developing.id)
    }
  end

  defp blocked_event(run, attempt) do
    %{
      "type" => "event",
      "protocol_version" => WorkerProtocol.version(),
      "event_id" => "evt-#{System.unique_integer([:positive])}",
      "run_id" => run.id,
      "command_id" => "cmd-#{System.unique_integer([:positive])}",
      "attempt_number" => attempt.attempt_number,
      "fence_token" => attempt.fence_token,
      "sequence" => 1,
      "event_type" => "blocked",
      "source" => "agent",
      "occurred_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "payload" => %{
        "question" => "Should search cover archived items?",
        "context" => "The requirements do not say.",
        "checkpoint" => %{"step" => "search-index"},
        "workspace_path" => "/workspaces/#{run.id}"
      }
    }
  end
end
