defmodule SddOrchestrator.Repo.Migrations.CreateActivityEntries do
  use Ecto.Migration

  def change do
    create table(:activity_entries, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :feature_id, references(:features, type: :binary_id, on_delete: :delete_all),
        null: false

      add :run_id, references(:agent_runs, type: :binary_id, on_delete: :nilify_all)
      add :attempt_id, references(:run_attempts, type: :binary_id, on_delete: :nilify_all)

      # A participant entry names its account; an agent or system entry has no
      # account at all rather than a placeholder one.
      add :actor_kind, :string, null: false
      add :actor_account_id, references(:accounts, type: :binary_id, on_delete: :nilify_all)

      add :type, :string, null: false

      # Authoritative order within one feature. It is assigned inside the
      # appending transaction, so two concurrent appends cannot claim the same
      # position: the loser is rejected and retries.
      add :sequence, :integer, null: false
      add :occurred_at, :utc_datetime_usec, null: false

      add :payload, :map, null: false, default: %{}

      # Append-only: there is no `updated_at` because an entry is never updated.
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:activity_entries, [:feature_id, :sequence])
    create index(:activity_entries, [:project_id])
    create index(:activity_entries, [:run_id])
    create index(:activity_entries, [:attempt_id])
    create index(:activity_entries, [:actor_account_id])

    create constraint(:activity_entries, :activity_entries_actor_kind_allowed,
             check: "actor_kind IN ('participant', 'agent', 'system')"
           )

    create constraint(:activity_entries, :activity_entries_type_allowed,
             check: """
             type IN
               ('assignment_changed', 'comment', 'evidence_recorded', 'preview_updated',
                'progress', 'question_answered', 'question_asked', 'readiness_evaluated',
                'reconciled', 'retry_scheduled', 'review_approved', 'review_rejected',
                'revocation_applied', 'run_canceled', 'run_completed', 'run_failed',
                'run_started', 'suggestion_dismissed')
             """
           )

    create constraint(:activity_entries, :activity_entries_sequence_positive,
             check: "sequence > 0"
           )

    # Only a participant entry carries an account. An agent or system entry with
    # an account would let machine output be attributed to a person.
    create constraint(:activity_entries, :activity_entries_actor_pairing,
             check: """
             (actor_kind = 'participant' AND actor_account_id IS NOT NULL)
               OR (actor_kind <> 'participant' AND actor_account_id IS NULL)
             """
           )

    # History is immutable at the database, not merely by convention: no code
    # path, migration, or console session can rewrite a recorded entry. Deletion
    # stays available so project deletion and retention still work.
    execute """
            CREATE OR REPLACE FUNCTION activity_entries_reject_update()
            RETURNS trigger AS $$
            BEGIN
              RAISE EXCEPTION 'activity_entries is append-only';
            END;
            $$ LANGUAGE plpgsql;
            """,
            "DROP FUNCTION IF EXISTS activity_entries_reject_update();"

    execute """
            CREATE TRIGGER activity_entries_no_update
            BEFORE UPDATE ON activity_entries
            FOR EACH ROW EXECUTE FUNCTION activity_entries_reject_update();
            """,
            "DROP TRIGGER IF EXISTS activity_entries_no_update ON activity_entries;"
  end
end
