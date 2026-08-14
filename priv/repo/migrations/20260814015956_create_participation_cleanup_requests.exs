defmodule SddOrchestrator.Repo.Migrations.CreateParticipationCleanupRequests do
  use Ecto.Migration

  # specs/28 Task 2 (AC-02, AC-03): restricted, non-identity-bearing propagation
  # and reconciliation state for participation deletion and anonymization
  # cleanup requests sent to configured processors, caches, indexes, and
  # exports. This table holds no participation content: no email, display
  # name, account id foreign key, or hosted-identity id — only an opaque
  # subject reference (a caller-minted correlation UUID, unrelated to any
  # stable account or participant id), the fixed destination and action, a
  # deterministic idempotency key, and minimum acknowledgement, attempt,
  # timing, and normalized-failure state.
  def change do
    create table(:participation_cleanup_requests, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # Deliberately not a foreign key: a caller-minted opaque correlation
      # reference for one deletion or anonymization action, never the raw
      # account or participant id itself, so this table cannot become a new
      # identity index keyed by a stable identity foreign key.
      add :subject_ref, :binary_id, null: false

      add :action, :string, null: false
      add :destination, :string, null: false
      add :idempotency_key, :string, null: false

      add :state, :string, null: false, default: "pending"
      add :failure_reason, :string
      add :attempt_count, :integer, null: false, default: 0

      add :requested_at, :utc_datetime_usec, null: false
      add :last_attempted_at, :utc_datetime_usec
      add :acknowledged_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    # One row per (subject, action, destination): the idempotency boundary
    # itself. A repeat propagation call for the same approved action can never
    # create a duplicate cleanup request for the same destination.
    create unique_index(
             :participation_cleanup_requests,
             [:subject_ref, :action, :destination],
             name: :participation_cleanup_requests_subject_action_destination_index
           )

    # Reconciliation claims incomplete requests oldest-attempted-first.
    create index(:participation_cleanup_requests, [:state, :last_attempted_at])

    create constraint(
             :participation_cleanup_requests,
             :participation_cleanup_requests_action_allowed,
             check: "action IN ('delete', 'anonymize')"
           )

    create constraint(
             :participation_cleanup_requests,
             :participation_cleanup_requests_destination_allowed,
             check: "destination IN ('configured_processors', 'caches', 'indexes', 'exports')"
           )

    create constraint(
             :participation_cleanup_requests,
             :participation_cleanup_requests_state_allowed,
             check: "state IN ('pending', 'acknowledged', 'retry_pending')"
           )

    create constraint(
             :participation_cleanup_requests,
             :participation_cleanup_requests_failure_reason_allowed,
             check:
               "failure_reason IS NULL OR failure_reason IN ('timeout', 'destination_unavailable', 'rejected', 'transient_error')"
           )

    # Time-bounded state pairing, mirroring
    # `participation_support_elevations_revocation_pairing`: acknowledgement
    # and failure classification are properties the row itself enforces
    # rather than a caller convention.
    create constraint(
             :participation_cleanup_requests,
             :participation_cleanup_requests_acknowledgement_pairing,
             check: "(acknowledged_at IS NOT NULL) = (state = 'acknowledged')"
           )

    create constraint(
             :participation_cleanup_requests,
             :participation_cleanup_requests_retry_pairing,
             check: "(failure_reason IS NOT NULL) = (state = 'retry_pending')"
           )
  end
end
