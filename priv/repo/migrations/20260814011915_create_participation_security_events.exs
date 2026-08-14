defmodule SddOrchestrator.Repo.Migrations.CreateParticipationSecurityEvents do
  use Ecto.Migration

  # specs/27 Task 3 (AC-03): the retention-capable local sink backing
  # `SddOrchestrator.Privacy.ParticipationSecurityLog`. A row carries only the
  # closed event type, coarse outcome, fixed reason classification (required
  # only for the outcomes that need one), UTC occurrence time, and a fresh
  # non-secret correlation identifier — never a credential, email, project or
  # repository detail, provider payload, secret, or unrelated identity. Rows
  # are append-only (`updated_at: false`) and deleted outright by
  # `SddOrchestrator.Privacy.Retention`'s 30-day rule; nothing here is ever
  # updated in place.
  def change do
    create table(:participation_security_events, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :event_type, :string, null: false
      add :outcome, :string, null: false
      add :reason, :string
      add :occurred_at, :utc_datetime, null: false
      add :correlation_id, :binary_id, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:participation_security_events, [:occurred_at])

    create constraint(
             :participation_security_events,
             :participation_security_events_event_type_allowed,
             check:
               "event_type IN ('invitation_credential_rejected', 'invitation_acceptance_rejected', 'revocation_denied')"
           )

    create constraint(
             :participation_security_events,
             :participation_security_events_outcome_allowed,
             check: "outcome IN ('rejected', 'denied', 'failed')"
           )

    create constraint(
             :participation_security_events,
             :participation_security_events_reason_allowed,
             check:
               "reason IS NULL OR reason IN ('invalid_or_expired', 'unauthorized', 'not_a_participant', 'owner_cannot_leave')"
           )
  end
end
