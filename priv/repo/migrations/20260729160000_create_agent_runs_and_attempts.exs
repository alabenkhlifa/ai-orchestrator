defmodule SddOrchestrator.Repo.Migrations.CreateAgentRunsAndAttempts do
  use Ecto.Migration

  def change do
    create table(:agent_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :feature_id, references(:features, type: :binary_id, on_delete: :delete_all),
        null: false

      # The person who started the run keeps cancellation authority only while
      # they remain a current participant; the reference is cleared rather than
      # cascading so governed history survives account removal.
      add :initiator_account_id, references(:accounts, type: :binary_id, on_delete: :nilify_all)

      # Specification revisions are owned by the shared specification store, so
      # they are referenced by identity and digest rather than by foreign key:
      # a device-authoritative project's revisions never exist in this database.
      add :starting_revision_id, :string, null: false
      add :starting_revision_digest, :string, null: false
      add :effective_revision_id, :string, null: false
      add :effective_revision_digest, :string, null: false
      add :approved_slice, :string, null: false

      # One run owns exactly one isolated branch for its whole lifetime.
      add :branch, :string, null: false

      add :state, :string, null: false, default: "pending"
      add :failure_reason, :string
      add :current_attempt_number, :integer, null: false, default: 0
      add :state_version, :integer, null: false, default: 1

      timestamps(type: :utc_datetime)
    end

    create index(:agent_runs, [:project_id, :state])
    create index(:agent_runs, [:feature_id])
    create index(:agent_runs, [:initiator_account_id])
    create unique_index(:agent_runs, [:project_id, :branch])

    create constraint(:agent_runs, :agent_runs_state_allowed,
             check: """
             state IN
               ('pending', 'running', 'blocked', 'failed', 'canceled', 'completed')
             """
           )

    create constraint(:agent_runs, :agent_runs_state_version_positive, check: "state_version > 0")

    create constraint(:agent_runs, :agent_runs_attempt_number_not_negative,
             check: "current_attempt_number >= 0"
           )

    # A failure reason belongs to a failed run and nowhere else, so a stale
    # reason cannot survive a later recovery.
    create constraint(:agent_runs, :agent_runs_failure_reason_placement,
             check: "failure_reason IS NULL OR state = 'failed'"
           )

    create table(:run_attempts, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :run_id, references(:agent_runs, type: :binary_id, on_delete: :delete_all), null: false

      add :attempt_number, :integer, null: false
      add :state, :string, null: false, default: "pending"
      add :continuation_reason, :string, null: false

      add :effective_revision_id, :string, null: false
      add :effective_revision_digest, :string, null: false
      add :manifest_digest, :string, null: false

      # One exclusive execution lease per attempt. The fence token orders leases
      # so a superseded worker's late events fail closed.
      add :lease_owner, :string
      add :lease_expires_at, :utc_datetime
      add :fence_token, :integer, null: false
      add :last_sequence, :integer, null: false, default: 0

      add :state_version, :integer, null: false, default: 1

      timestamps(type: :utc_datetime)
    end

    create unique_index(:run_attempts, [:run_id, :attempt_number])
    create unique_index(:run_attempts, [:run_id, :fence_token])
    create index(:run_attempts, [:state])

    # At most one attempt of a run may be current. This is the database-level
    # form of "one run has one current attempt": a duplicate dispatch, a
    # reconnecting worker, or a racing retry cannot create a second.
    create unique_index(:run_attempts, [:run_id],
             where: "state IN ('pending', 'dispatched', 'running')",
             name: :run_attempts_one_current_attempt
           )

    create constraint(:run_attempts, :run_attempts_state_allowed,
             check: """
             state IN
               ('pending', 'dispatched', 'running', 'succeeded', 'failed', 'canceled',
                'superseded')
             """
           )

    create constraint(:run_attempts, :run_attempts_attempt_number_positive,
             check: "attempt_number > 0"
           )

    create constraint(:run_attempts, :run_attempts_fence_token_positive, check: "fence_token > 0")

    create constraint(:run_attempts, :run_attempts_last_sequence_not_negative,
             check: "last_sequence >= 0"
           )

    create constraint(:run_attempts, :run_attempts_state_version_positive,
             check: "state_version > 0"
           )

    # A lease is a pair: an owner without an expiry (or the reverse) would let a
    # stale claim look current forever.
    create constraint(:run_attempts, :run_attempts_lease_pairing,
             check: """
             (lease_owner IS NULL AND lease_expires_at IS NULL)
               OR (lease_owner IS NOT NULL AND lease_expires_at IS NOT NULL)
             """
           )
  end
end
