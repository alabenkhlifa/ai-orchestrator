defmodule SddOrchestrator.Delivery.BlockingTest do
  @moduledoc """
  Proof for durable blocked-run and question state (Task 22).

  Two promises are being pinned here. A paused run keeps everything a later
  attempt needs — the branch, the workspace, and the checkpoint — so an answer
  continues accepted work instead of repeating it. And a paused feature does not
  move: `Blocked` is a status on a feature that is still in `In development`,
  which is asserted on every path that reaches it.
  """
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Delivery.{
    ActivityEntry,
    AgentRun,
    Blocking,
    BlockingQuestion,
    EventIngestion,
    Feature,
    RunAttempt,
    RunStatus,
    WorkerProtocol
  }

  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.Repo

  setup do
    context = DeliveryFixtures.delivery_project_fixture()

    feature =
      context.project |> DeliveryFixtures.feature_fixture(context.account) |> in_development()

    run = DeliveryFixtures.run_fixture(context.project, feature)
    pending = DeliveryFixtures.attempt_fixture(run, %{fence_token: 3})

    {:ok, attempt} =
      pending
      |> RunAttempt.transition_changeset("dispatched", pending.state_version)
      |> Repo.update()

    # A run reports that it is working before it reports that it is stuck, so
    # the blocked path is exercised from the state it really sees.
    {:ok, _progress} =
      EventIngestion.ingest(context.workspace, context.project.id, progress(run, attempt))

    %{
      authority: context.workspace,
      actor: context.owner_actor,
      project: context.project,
      feature: feature,
      run: run,
      attempt: attempt
    }
  end

  describe "pausing a run on a question" do
    test "blocks the run, keeps the feature in development, and shows the status [AC-02]", %{
      authority: authority,
      project: project,
      feature: feature,
      run: run,
      attempt: attempt
    } do
      assert {:ok, results} =
               Blocking.ingest(authority, project.id, blocked(run, attempt, sequence: 2))

      assert results.run.state == "blocked"
      assert Repo.get!(AgentRun, run.id).state == "blocked"

      reloaded = Repo.get!(Feature, feature.id)
      assert reloaded.lifecycle_column == "in_development"
      assert reloaded.status == "blocked"
      assert RunStatus.for_run(Repo.get!(AgentRun, run.id)) == "blocked"
    end

    test "stores one focused question with its context [AC-17]", %{
      authority: authority,
      project: project,
      feature: feature,
      run: run,
      attempt: attempt
    } do
      {:ok, results} =
        Blocking.ingest(
          authority,
          project.id,
          blocked(run, attempt,
            sequence: 2,
            question: "Should a departed member's comments stay visible?",
            context: "The retention rule says active project lifetime."
          )
        )

      assert results.question.question == "Should a departed member's comments stay visible?"
      assert results.question.context == "The retention rule says active project lifetime."
      assert results.question.state == "open"
      assert results.question.project_id == project.id
      assert results.question.feature_id == feature.id
      assert results.question.run_id == run.id
      assert results.question.attempt_id == attempt.id
    end

    test "preserves the branch, the workspace, and the checkpoint", %{
      authority: authority,
      project: project,
      run: run,
      attempt: attempt
    } do
      checkpoint = %{"stage" => "requirements", "commits" => ["abc123"]}

      {:ok, results} =
        Blocking.ingest(
          authority,
          project.id,
          blocked(run, attempt,
            sequence: 2,
            checkpoint: checkpoint,
            workspace_path: "/var/sdd/workspaces/run-1"
          )
        )

      stored = Repo.get!(BlockingQuestion, results.question.id)

      assert stored.checkpoint == checkpoint
      assert stored.workspace_path == "/var/sdd/workspaces/run-1"
      assert stored.branch == run.branch
    end

    test "the branch comes from the run, never from the worker", %{
      authority: authority,
      project: project,
      run: run,
      attempt: attempt
    } do
      envelope = blocked(run, attempt, sequence: 2)

      envelope =
        Map.put(envelope, "payload", Map.put(envelope["payload"], "branch", "main"))

      {:ok, results} = Blocking.ingest(authority, project.id, envelope)

      assert results.question.branch == run.branch
    end

    test "records one question in the feature's history", %{
      authority: authority,
      project: project,
      feature: feature,
      run: run,
      attempt: attempt
    } do
      {:ok, results} =
        Blocking.ingest(
          authority,
          project.id,
          blocked(run, attempt, sequence: 2, question: "Which retention window applies?")
        )

      assert results.activity.type == "question_asked"
      assert results.activity.actor_kind == "agent"
      refute results.activity.actor_account_id
      assert results.activity.run_id == run.id
      assert results.activity.attempt_id == attempt.id
      assert results.activity.payload["question_id"] == results.question.id
      assert results.activity.payload["branch"] == run.branch
      assert results.activity.payload["summary"] == "Which retention window applies?"

      assert Repo.aggregate(
               from(e in ActivityEntry,
                 where: e.feature_id == ^feature.id and e.type == "question_asked"
               ),
               :count
             ) == 1
    end

    test "advances the attempt's observed sequence", %{
      authority: authority,
      project: project,
      run: run,
      attempt: attempt
    } do
      {:ok, _results} = Blocking.ingest(authority, project.id, blocked(run, attempt, sequence: 7))

      assert Repo.get!(RunAttempt, attempt.id).last_sequence == 7
    end
  end

  describe "keeping one question open at a time" do
    test "a second blocked event never creates a second question", %{
      authority: authority,
      project: project,
      run: run,
      attempt: attempt
    } do
      {:ok, _first} = Blocking.ingest(authority, project.id, blocked(run, attempt, sequence: 2))

      assert {:error, :question_already_open} =
               Blocking.ingest(authority, project.id, blocked(run, attempt, sequence: 3))

      assert Repo.aggregate(BlockingQuestion, :count) == 1
    end

    test "the database refuses a second open question for one run", %{
      project: project,
      feature: feature,
      run: run
    } do
      {:ok, _first} = Repo.insert(question_changeset(project, feature, run))

      assert {:error, changeset} = Repo.insert(question_changeset(project, feature, run))
      assert Keyword.has_key?(changeset.errors, :state)
      assert Repo.aggregate(BlockingQuestion, :count) == 1
    end

    test "a resolved question frees the run to ask the next one", %{
      project: project,
      feature: feature,
      run: run
    } do
      {:ok, first} = Repo.insert(question_changeset(project, feature, run))

      {:ok, answered} =
        first
        |> BlockingQuestion.resolve_changeset(
          "answered",
          first.state_version,
          Ecto.UUID.generate()
        )
        |> Repo.update()

      assert answered.state == "answered"
      assert {:ok, _second} = Repo.insert(question_changeset(project, feature, run))
      assert Repo.aggregate(BlockingQuestion, :count) == 2
    end

    test "an answered question cannot be resolved again", %{
      project: project,
      feature: feature,
      run: run
    } do
      {:ok, first} = Repo.insert(question_changeset(project, feature, run))

      {:ok, answered} =
        first
        |> BlockingQuestion.resolve_changeset(
          "answered",
          first.state_version,
          Ecto.UUID.generate()
        )
        |> Repo.update()

      changeset =
        BlockingQuestion.resolve_changeset(answered, "superseded", answered.state_version)

      refute changeset.valid?
    end

    test "a resolution offered against a superseded version is refused", %{
      project: project,
      feature: feature,
      run: run
    } do
      {:ok, question} = Repo.insert(question_changeset(project, feature, run))

      changeset =
        BlockingQuestion.resolve_changeset(
          question,
          "answered",
          question.state_version + 1,
          Ecto.UUID.generate()
        )

      refute changeset.valid?
    end
  end

  describe "rejecting what must not pause a run" do
    test "a superseded worker's fence pauses nothing", %{
      authority: authority,
      project: project,
      feature: feature,
      run: run,
      attempt: attempt
    } do
      envelope = blocked(run, attempt, sequence: 2, fence_token: 2)

      assert {:error, :stale_fence} = Blocking.ingest(authority, project.id, envelope)

      assert Repo.aggregate(BlockingQuestion, :count) == 0
      assert Repo.get!(AgentRun, run.id).state == "running"
      assert Repo.get!(Feature, feature.id).status == "none"
    end

    test "a replayed event is a duplicate, not a second question", %{
      authority: authority,
      project: project,
      run: run,
      attempt: attempt
    } do
      {:ok, _first} = Blocking.ingest(authority, project.id, blocked(run, attempt, sequence: 2))

      assert {:error, :duplicate_event} =
               Blocking.ingest(authority, project.id, blocked(run, attempt, sequence: 2))

      assert Repo.aggregate(BlockingQuestion, :count) == 1
    end

    test "an out-of-order event is refused", %{
      authority: authority,
      project: project,
      run: run,
      attempt: attempt
    } do
      {:ok, _first} = Blocking.ingest(authority, project.id, blocked(run, attempt, sequence: 5))

      assert {:error, :stale_sequence} =
               Blocking.ingest(authority, project.id, blocked(run, attempt, sequence: 4))

      assert Repo.aggregate(BlockingQuestion, :count) == 1
    end

    test "an envelope failing the protocol schema never reaches storage", %{
      authority: authority,
      project: project,
      run: run,
      attempt: attempt
    } do
      base = blocked(run, attempt, sequence: 2)
      malformed = Map.delete(base, "occurred_at")
      unknown_field = Map.put(base, "extra", "nope")
      credential = Map.put(base, "payload", Map.put(base["payload"], "api_key", "sk-abcdef"))

      for envelope <- [malformed, unknown_field, credential] do
        assert {:error, _reason} = Blocking.ingest(authority, project.id, envelope)
      end

      assert Repo.aggregate(BlockingQuestion, :count) == 0
    end

    test "an event type this module does not own is refused", %{
      authority: authority,
      project: project,
      run: run,
      attempt: attempt
    } do
      for type <- WorkerProtocol.event_types() -- [Blocking.event_type()] do
        envelope = run |> blocked(attempt, sequence: 2) |> Map.put("event_type", type)

        assert {:error, :unsupported_event} = Blocking.ingest(authority, project.id, envelope)
      end
    end

    test "progress ingestion still refuses the blocked event this module owns", %{
      authority: authority,
      project: project,
      run: run,
      attempt: attempt
    } do
      assert {:error, :unsupported_event} =
               EventIngestion.ingest(authority, project.id, blocked(run, attempt, sequence: 2))

      assert Repo.aggregate(BlockingQuestion, :count) == 0
    end

    test "a question without its resumable state is refused rather than stored", %{
      authority: authority,
      project: project,
      run: run,
      attempt: attempt
    } do
      blank = blocked(run, attempt, sequence: 2, question: "   ")
      missing_workspace = blocked(run, attempt, sequence: 2, workspace_path: nil)
      oversized = blocked(run, attempt, sequence: 2, question: String.duplicate("x", 2_001))

      long_context =
        blocked(run, attempt, sequence: 2, context: String.duplicate("y", 4_001))

      for envelope <- [blank, missing_workspace, oversized, long_context] do
        assert {:error, :invalid_question} = Blocking.ingest(authority, project.id, envelope)
      end

      assert Repo.aggregate(BlockingQuestion, :count) == 0
      assert Repo.get!(AgentRun, run.id).state == "running"
    end

    test "an oversized checkpoint is refused", %{
      authority: authority,
      project: project,
      run: run,
      attempt: attempt
    } do
      envelope =
        blocked(run, attempt,
          sequence: 2,
          checkpoint: %{"log" => String.duplicate("z", 4_100)}
        )

      assert {:error, :invalid_question} = Blocking.ingest(authority, project.id, envelope)
      assert Repo.aggregate(BlockingQuestion, :count) == 0
    end

    test "a run that has not reported it is working cannot report it is stuck", %{
      authority: authority,
      project: project,
      feature: feature
    } do
      pending_run = DeliveryFixtures.run_fixture(project, feature)
      pending_attempt = DeliveryFixtures.attempt_fixture(pending_run, %{fence_token: 9})

      assert {:error, :run_not_running} =
               Blocking.ingest(
                 authority,
                 project.id,
                 blocked(pending_run, pending_attempt, sequence: 1)
               )

      assert Repo.aggregate(BlockingQuestion, :count) == 0
      assert Repo.get!(AgentRun, pending_run.id).state == "pending"
    end

    test "an event for an unknown run is refused", %{
      authority: authority,
      project: project,
      run: run,
      attempt: attempt
    } do
      envelope =
        run |> blocked(attempt, sequence: 2) |> Map.put("run_id", Ecto.UUID.generate())

      assert {:error, :unknown_run} = Blocking.ingest(authority, project.id, envelope)
    end

    test "an event for another project's run is refused", %{
      authority: authority,
      run: run,
      attempt: attempt
    } do
      other = DeliveryFixtures.delivery_project_fixture()

      assert {:error, :unknown_run} =
               Blocking.ingest(authority, other.project.id, blocked(run, attempt, sequence: 2))
    end
  end

  describe "reading the open question" do
    test "a run with no question has none", %{authority: authority, project: project, run: run} do
      assert :error = Blocking.open_question(authority, project.id, run.id)
    end

    test "the run's open question is readable", %{
      authority: authority,
      project: project,
      run: run,
      attempt: attempt
    } do
      {:ok, results} = Blocking.ingest(authority, project.id, blocked(run, attempt, sequence: 2))

      assert {:ok, question} = Blocking.open_question(authority, project.id, run.id)
      assert question.id == results.question.id
    end

    test "the feature's open question is readable by a current member", %{
      authority: authority,
      actor: actor,
      project: project,
      feature: feature,
      run: run,
      attempt: attempt
    } do
      assert {:ok, nil} = Blocking.for_feature(project.id, actor, feature.id)

      {:ok, results} = Blocking.ingest(authority, project.id, blocked(run, attempt, sequence: 2))

      assert {:ok, question} = Blocking.for_feature(project.id, actor, feature.id)
      assert question.id == results.question.id
    end

    test "an outsider reads no question", %{project: project, feature: feature} do
      outsider = SddOrchestrator.AccountsFixtures.account_fixture()

      assert {:error, :unauthorized} =
               Blocking.for_feature(
                 project.id,
                 %{account_id: outsider.id, hosted_identity_id: nil},
                 feature.id
               )
    end
  end

  defp in_development(feature) do
    {:ok, ready} =
      feature
      |> Feature.transition_changeset("ready_for_development", feature.state_version)
      |> Repo.update()

    {:ok, developing} =
      ready
      |> Feature.transition_changeset("in_development", ready.state_version)
      |> Repo.update()

    developing
  end

  defp question_changeset(project, feature, run) do
    BlockingQuestion.ask_changeset(%BlockingQuestion{}, %{
      project_id: project.id,
      feature_id: feature.id,
      run_id: run.id,
      question: "Which retention window applies?",
      branch: run.branch,
      workspace_path: "/var/sdd/workspaces/#{run.id}"
    })
  end

  defp progress(run, attempt) do
    run
    |> envelope(attempt, sequence: 1)
    |> Map.put("event_type", "progress")
    |> Map.put("payload", %{"summary" => "Working"})
  end

  defp blocked(run, attempt, opts) do
    payload =
      %{
        "question" => Keyword.get(opts, :question, "Which retention window applies?"),
        "checkpoint" => Keyword.get(opts, :checkpoint, %{"stage" => "requirements"}),
        "workspace_path" => Keyword.get(opts, :workspace_path, "/var/sdd/workspaces/#{run.id}")
      }
      |> put_optional("context", Keyword.get(opts, :context))

    run |> envelope(attempt, opts) |> Map.put("payload", payload)
  end

  defp put_optional(payload, _key, nil), do: payload
  defp put_optional(payload, key, value), do: Map.put(payload, key, value)

  defp envelope(run, attempt, opts) do
    %{
      "type" => "event",
      "protocol_version" => WorkerProtocol.version(),
      "event_id" => "evt-#{System.unique_integer([:positive])}",
      "run_id" => run.id,
      "command_id" => "cmd-#{System.unique_integer([:positive])}",
      "attempt_number" => attempt.attempt_number,
      "fence_token" => Keyword.get(opts, :fence_token, attempt.fence_token),
      "sequence" => Keyword.fetch!(opts, :sequence),
      "event_type" => "blocked",
      "source" => "agent",
      "occurred_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "payload" => %{}
    }
  end
end
