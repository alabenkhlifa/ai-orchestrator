defmodule SddOrchestrator.Delivery.ReviewDecisionTest do
  @moduledoc """
  Proof for the recorded review verdict itself (Task 34).

  One promise is pinned above the rest: a verdict is written once. There is no
  update changeset, and the database refuses `UPDATE` outright, so a rejection
  cannot later be edited into an approval and a decision cannot be repointed at
  another commit. The trigger is proved directly rather than inferred from the
  absence of a changeset.

  The second promise is that a verdict and its feedback belong together in both
  directions. A rejection without something to act on wastes the run it sends
  back; an approval carrying feedback is a record that reads as a complaint about
  work that was accepted. The changeset and a check constraint say so
  independently, because a raw insert must not be able to write what a caller
  cannot.

  The third is that one attempt has one verdict. That is what makes a
  double-submitted approval a refusal at the store rather than two decisions
  about the same proof.
  """
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Delivery.ReviewDecision
  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.Repo

  @commit "a1b2c3d4e5f6a7b8c9d0"
  @migration_version 20_260_731_120_000

  # The migration test rolls the whole table back, which needs an exclusive lock
  # on it and on every table it references. Giving that one test a bare sandbox
  # keeps it from deadlocking against rows its own setup would otherwise hold.
  setup context do
    if context[:migration], do: :ok, else: decision_setup()
  end

  defp decision_setup do
    hosted = DeliveryFixtures.delivery_project_fixture()
    feature = DeliveryFixtures.feature_fixture(hosted.project, hosted.account)

    %{run: run, attempt: attempt} =
      DeliveryFixtures.run_with_attempt_fixture(hosted.project, feature)

    %{
      project: hosted.project,
      account: hosted.account,
      feature: feature,
      run: run,
      attempt: attempt
    }
  end

  describe "the recording changeset" do
    test "accepts an approval with no feedback", context do
      assert {:ok, decision} = insert_decision(context, decision: "approved")

      assert ReviewDecision.approved?(decision)
      refute ReviewDecision.rejected?(decision)
      refute decision.feedback
      assert decision.state_version == 1
      assert decision.decided_at
    end

    test "accepts a rejection that says why", context do
      assert {:ok, decision} =
               insert_decision(context,
                 decision: "rejected",
                 feedback: "The empty state is wrong"
               )

      assert ReviewDecision.rejected?(decision)
      assert decision.feedback == "The empty state is wrong"
    end

    test "refuses a rejection with nothing to act on", context do
      assert {:error, changeset} = insert_decision(context, decision: "rejected", feedback: nil)
      assert "is required for a rejection" in errors_on(changeset).feedback

      assert {:error, blank} = insert_decision(context, decision: "rejected", feedback: "   ")
      assert "is required for a rejection" in errors_on(blank).feedback
    end

    test "refuses an approval that carries feedback", context do
      assert {:error, changeset} =
               insert_decision(context, decision: "approved", feedback: "looks fine")

      assert "is not allowed for an approval" in errors_on(changeset).feedback
    end

    test "refuses an outcome that is neither", context do
      assert {:error, changeset} = insert_decision(context, decision: "maybe")
      assert errors_on(changeset).decision != []
    end

    test "refuses feedback, a branch, or a commit past its byte limit", context do
      assert {:error, long_feedback} =
               insert_decision(context,
                 decision: "rejected",
                 feedback: String.duplicate("a", 4_001)
               )

      assert errors_on(long_feedback).feedback != []

      assert {:error, long_branch} =
               insert_decision(context, branch: String.duplicate("b", 201))

      assert errors_on(long_branch).branch != []

      assert {:error, long_commit} =
               insert_decision(context, commit_sha: String.duplicate("c", 65))

      assert errors_on(long_commit).commit_sha != []
    end

    test "refuses a verdict that names no reviewer, attempt, or commit", context do
      assert {:error, changeset} =
               insert_decision(context, reviewer_account_id: nil, attempt_id: nil, branch: nil)

      errors = errors_on(changeset)

      assert errors.reviewer_account_id != []
      assert errors.attempt_id != []
      assert errors.branch != []
    end

    test "refuses a second verdict about the same attempt", context do
      assert {:ok, _first} = insert_decision(context, decision: "approved")

      assert {:error, changeset} =
               insert_decision(context, decision: "rejected", feedback: "not so fast")

      assert errors_on(changeset).run_id != []
    end
  end

  describe "the hosted schema" do
    test "refuses a rejection with no feedback at the database", context do
      assert {:error, error} = insert_row(context, decision: "rejected", feedback: nil)
      assert error.postgres.constraint == "review_decisions_feedback_pairing"
    end

    test "refuses a rejection whose feedback is only whitespace", context do
      assert {:error, error} = insert_row(context, decision: "rejected", feedback: "   ")
      assert error.postgres.constraint == "review_decisions_feedback_pairing"
    end

    test "refuses an approval carrying feedback at the database", context do
      assert {:error, error} = insert_row(context, decision: "approved", feedback: "looks fine")
      assert error.postgres.constraint == "review_decisions_feedback_pairing"
    end

    test "refuses an outcome the product does not have", context do
      assert {:error, error} = insert_row(context, decision: "deferred")
      assert error.postgres.constraint == "review_decisions_decision_allowed"
    end

    test "refuses a branch or commit past its byte limit", context do
      assert {:error, branch} = insert_row(context, branch: String.duplicate("b", 201))
      assert branch.postgres.constraint == "review_decisions_branch_length"

      assert {:error, commit} = insert_row(context, commit_sha: String.duplicate("c", 65))
      assert commit.postgres.constraint == "review_decisions_commit_sha_length"
    end

    test "refuses a state version that is not positive", context do
      assert {:error, error} = insert_row(context, state_version: 0)
      assert error.postgres.constraint == "review_decisions_state_version_positive"
    end

    test "refuses a second verdict about the same run and attempt", context do
      assert {:ok, _first} = insert_row(context, [])
      assert {:error, error} = insert_row(context, decision: "rejected", feedback: "again")
      assert error.postgres.constraint == "review_decisions_attempt_index"
    end

    test "refuses every later rewrite of a recorded verdict", context do
      {:ok, %{rows: [[id]]}} = insert_row(context, decision: "rejected", feedback: "please fix")

      assert {:error, outcome} =
               Repo.query("UPDATE review_decisions SET decision = $1 WHERE id = $2", [
                 "approved",
                 id
               ])

      assert outcome.postgres.message =~ "recorded once"

      # Not only the outcome: no column of a recorded verdict may move.
      assert {:error, commit} =
               Repo.query("UPDATE review_decisions SET commit_sha = $1 WHERE id = $2", [
                 "ffffffffffffffffffff",
                 id
               ])

      assert commit.postgres.message =~ "recorded once"
    end
  end

  describe "the device value shape" do
    test "round-trips every recorded field", context do
      {:ok, decision} =
        insert_decision(context, decision: "rejected", feedback: "The empty state is wrong")

      assert {:ok, restored} =
               decision |> ReviewDecision.to_value() |> ReviewDecision.from_value()

      assert restored.id == decision.id
      assert restored.project_id == decision.project_id
      assert restored.feature_id == decision.feature_id
      assert restored.run_id == decision.run_id
      assert restored.attempt_id == decision.attempt_id
      assert restored.decision == decision.decision
      assert restored.feedback == decision.feedback
      assert restored.reviewer_account_id == decision.reviewer_account_id
      assert restored.branch == decision.branch
      assert restored.commit_sha == decision.commit_sha
      assert restored.preview_deployment_id == decision.preview_deployment_id
      assert restored.state_version == decision.state_version
      assert DateTime.compare(restored.decided_at, decision.decided_at) == :eq
    end

    test "refuses a value the device store could not have written", context do
      {:ok, decision} = insert_decision(context, decision: "approved")
      value = ReviewDecision.to_value(decision)

      assert {:error, :invalid_review_decision_value} =
               ReviewDecision.from_value(Map.put(value, "decision", "deferred"))

      # An approval that grew feedback, and a rejection that lost it, are each
      # a record that lies about what happened.
      assert {:error, :invalid_review_decision_value} =
               ReviewDecision.from_value(Map.put(value, "feedback", "looks fine"))

      assert {:error, :invalid_review_decision_value} =
               ReviewDecision.from_value(Map.merge(value, %{"decision" => "rejected"}))

      assert {:error, :invalid_review_decision_value} =
               ReviewDecision.from_value(Map.put(value, "reviewer_account_id", nil))

      assert {:error, :invalid_review_decision_value} =
               ReviewDecision.from_value(Map.put(value, "decided_at", nil))

      assert {:error, :invalid_review_decision_value} =
               ReviewDecision.from_value(Map.put(value, "state_version", 0))

      assert {:error, :invalid_review_decision_value} = ReviewDecision.from_value(%{})
      assert {:error, :invalid_review_decision_value} = ReviewDecision.from_value("not a record")
    end
  end

  describe "the migration" do
    @describetag migration: true

    test "rolls back and forward again" do
      module = migration_module()

      assert table_exists?("review_decisions")

      # The lock is disabled because it would hold a second connection the Ecto
      # sandbox does not have. The migration itself still runs for real, inside
      # this test's transaction, so the rollback is proven and then undone.
      opts = [log: false, migration_lock: false]

      assert :ok = Ecto.Migrator.down(Repo, @migration_version, module, opts)
      refute table_exists?("review_decisions")
      refute trigger_exists?("review_decisions_no_update")

      assert :ok = Ecto.Migrator.up(Repo, @migration_version, module, opts)
      assert table_exists?("review_decisions")
      assert trigger_exists?("review_decisions_no_update")
    end
  end

  defp insert_decision(context, overrides) do
    %ReviewDecision{}
    |> ReviewDecision.record_changeset(decision_attrs(context, overrides))
    |> Repo.insert()
  end

  defp decision_attrs(context, overrides) do
    Map.merge(
      %{
        project_id: context.project.id,
        feature_id: context.feature.id,
        run_id: context.run.id,
        attempt_id: context.attempt.id,
        decision: "approved",
        feedback: nil,
        reviewer_account_id: context.account.id,
        branch: context.run.branch,
        commit_sha: @commit
      },
      Map.new(overrides)
    )
  end

  # Raw inserts, so a constraint is proved against the database rather than
  # against the changeset that normally keeps callers away from it.
  defp insert_row(context, overrides) do
    attrs =
      Map.merge(
        %{
          decision: "approved",
          feedback: nil,
          branch: context.run.branch,
          commit_sha: @commit,
          state_version: 1
        },
        Map.new(overrides)
      )

    Repo.query(
      """
      INSERT INTO review_decisions
        (id, project_id, feature_id, run_id, attempt_id, decision, feedback,
         reviewer_account_id, branch, commit_sha, decided_at, state_version,
         inserted_at, updated_at)
      VALUES
        ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, NOW(), $11, NOW(), NOW())
      RETURNING id
      """,
      [
        Ecto.UUID.bingenerate(),
        Ecto.UUID.dump!(context.project.id),
        Ecto.UUID.dump!(context.feature.id),
        Ecto.UUID.dump!(context.run.id),
        Ecto.UUID.dump!(context.attempt.id),
        attrs.decision,
        attrs.feedback,
        Ecto.UUID.dump!(context.account.id),
        attrs.branch,
        attrs.commit_sha,
        attrs.state_version
      ]
    )
  end

  defp migration_module do
    module = SddOrchestrator.Repo.Migrations.CreateReviewDecisions

    if Code.ensure_loaded?(module) do
      module
    else
      path =
        Path.join([
          File.cwd!(),
          "priv/repo/migrations/20260731120000_create_review_decisions.exs"
        ])

      [{loaded, _binary} | _rest] = Code.compile_file(path)
      loaded
    end
  end

  defp table_exists?(table) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM information_schema.tables WHERE table_name = $1",
        [table]
      )

    count == 1
  end

  defp trigger_exists?(trigger) do
    %{rows: [[count]]} =
      Repo.query!("SELECT count(*) FROM pg_trigger WHERE tgname = $1", [trigger])

    count == 1
  end
end
