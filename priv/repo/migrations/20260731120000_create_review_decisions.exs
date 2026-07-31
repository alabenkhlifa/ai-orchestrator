defmodule SddOrchestrator.Repo.Migrations.CreateReviewDecisions do
  use Ecto.Migration

  def change do
    create table(:review_decisions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :feature_id, references(:features, type: :binary_id, on_delete: :delete_all),
        null: false

      add :run_id, references(:agent_runs, type: :binary_id, on_delete: :delete_all), null: false

      # A decision is *about* one attempt's proof. Losing the attempt would leave
      # a verdict nobody can place, so the link is required and cascades rather
      # than being cleared.
      add :attempt_id, references(:run_attempts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :decision, :string, null: false

      # Why the work was sent back, in the reviewer's own words. Required for a
      # rejection because the next attempt has nothing to act on without it, and
      # forbidden for an approval because an approval carrying feedback is a
      # record that lies about what happened.
      add :feedback, :text

      add :reviewer_account_id, references(:accounts, type: :binary_id, on_delete: :nilify_all)

      # Exactly what was reviewed, copied from the recorded verified completion.
      # A decision that named the run's current branch and head instead would
      # drift away from the commit whose proof the reviewer actually read.
      add :branch, :string, null: false
      add :commit_sha, :string, null: false

      # The preview the reviewer could have opened, when one existed. Recorded
      # as a plain reference rather than a foreign key on purpose: a preview is a
      # convenience and never a verdict, so it must not be able to block a
      # governed decision from being written, kept, or released. A
      # device-authoritative project's preview does not live in this database at
      # all, which is the same reason stated a second way.
      add :preview_deployment_id, :binary_id

      add :decided_at, :utc_datetime_usec, null: false
      add :state_version, :integer, null: false, default: 1

      timestamps(type: :utc_datetime_usec)
    end

    create index(:review_decisions, [:project_id])
    create index(:review_decisions, [:feature_id])
    create index(:review_decisions, [:reviewer_account_id])

    # One attempt, one verdict. Idempotency as a property of the store rather
    # than of callers: a double-submitted approval cannot become two decisions,
    # whichever process asks.
    create unique_index(:review_decisions, [:run_id, :attempt_id],
             name: :review_decisions_attempt_index
           )

    create constraint(:review_decisions, :review_decisions_decision_allowed,
             check: "decision IN ('approved', 'rejected')"
           )

    # Both directions, because each half prevents a different defect: a
    # rejection nobody can act on, and an approval that reads as a complaint.
    create constraint(:review_decisions, :review_decisions_feedback_pairing,
             check: """
             (decision = 'rejected' AND feedback IS NOT NULL AND btrim(feedback) <> '')
               OR (decision = 'approved' AND feedback IS NULL)
             """
           )

    create constraint(:review_decisions, :review_decisions_feedback_length,
             check: "feedback IS NULL OR octet_length(feedback) <= 4000"
           )

    create constraint(:review_decisions, :review_decisions_branch_length,
             check: "octet_length(branch) > 0 AND octet_length(branch) <= 200"
           )

    create constraint(:review_decisions, :review_decisions_commit_sha_length,
             check: "octet_length(commit_sha) > 0 AND octet_length(commit_sha) <= 64"
           )

    create constraint(:review_decisions, :review_decisions_state_version_positive,
             check: "state_version > 0"
           )

    # A recorded verdict is immutable at the database, not merely by convention:
    # no code path, migration, or console session can turn a rejection into an
    # approval or repoint one at another commit. Deletion stays available so
    # project deletion and retention still work.
    execute """
            CREATE OR REPLACE FUNCTION review_decisions_reject_update()
            RETURNS trigger AS $$
            BEGIN
              RAISE EXCEPTION 'a review decision is recorded once';
            END;
            $$ LANGUAGE plpgsql;
            """,
            "DROP FUNCTION IF EXISTS review_decisions_reject_update();"

    execute """
            CREATE TRIGGER review_decisions_no_update
            BEFORE UPDATE ON review_decisions
            FOR EACH ROW EXECUTE FUNCTION review_decisions_reject_update();
            """,
            "DROP TRIGGER IF EXISTS review_decisions_no_update ON review_decisions;"
  end
end
