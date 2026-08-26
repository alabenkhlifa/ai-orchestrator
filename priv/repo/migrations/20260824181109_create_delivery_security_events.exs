defmodule SddOrchestrator.Repo.Migrations.CreateDeliverySecurityEvents do
  use Ecto.Migration

  # specs/19 Task 4: the persisted, minimized local sink backing
  # `SddOrchestrator.Privacy.DeliverySecurityLog`. A row carries only the
  # closed guided-delivery event type, coarse outcome, fixed reason
  # classification (required only for the outcomes that need one), UTC
  # occurrence time, and a fresh non-secret correlation identifier — never a
  # project, feature, run, attempt, command, participant, worker, or provider
  # identifier, and never specification content, comment text, evidence bytes,
  # a preview link, a credential, or an email. Rows are append-only
  # (`updated_at: false`); the 30-day expiry that scans `occurred_at` is a
  # later task's work, so nothing here is ever updated in place.
  def change do
    create table(:delivery_security_events, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :event_type, :string, null: false
      add :outcome, :string, null: false
      add :reason, :string
      add :occurred_at, :utc_datetime, null: false
      add :correlation_id, :binary_id, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    # `occurred_at` backs the later 30-day expiry sweep; `event_type` backs
    # per-category operational review of the closed vocabulary.
    create index(:delivery_security_events, [:occurred_at])
    create index(:delivery_security_events, [:event_type])

    create constraint(
             :delivery_security_events,
             :delivery_security_events_event_type_allowed,
             check: """
             event_type IN (
               'worker_command_rejected',
               'agent_adapter_rejected',
               'delivery_access_denied',
               'evidence_artifact_rejected',
               'retention_sweep_failed'
             )
             """
           )

    create constraint(
             :delivery_security_events,
             :delivery_security_events_outcome_allowed,
             check: "outcome IN ('rejected', 'denied', 'failed')"
           )

    create constraint(
             :delivery_security_events,
             :delivery_security_events_reason_allowed,
             check: """
             reason IS NULL OR reason IN (
               'credential_detected',
               'email_detected',
               'raw_event_detected',
               'secret_field_rejected',
               'secret_material_rejected',
               'unauthorized',
               'not_found'
             )
             """
           )
  end
end
