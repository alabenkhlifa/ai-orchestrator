defmodule SddOrchestrator.Repo.Migrations.CreateParticipationEmailDeliveries do
  use Ecto.Migration

  def change do
    create table(:participation_email_deliveries, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :event_type, :string, null: false
      add :subject_ref, :binary_id, null: false
      add :event_version, :integer, null: false, default: 1
      add :recipient_address, :binary, null: false
      add :status, :string, null: false, default: "pending"
      add :failure_code, :string
      add :attempted_at, :utc_datetime, null: false
      add :delivered_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    # One delivery attempt record per event, subject, and subject version, so a
    # retried lifecycle action replaces its outcome instead of duplicating it.
    create unique_index(
             :participation_email_deliveries,
             [:event_type, :subject_ref, :event_version],
             name: :participation_email_deliveries_event_subject_index
           )

    create index(:participation_email_deliveries, [:status, :attempted_at])

    create constraint(
             :participation_email_deliveries,
             :participation_email_deliveries_status_allowed,
             check: "status IN ('pending', 'sent', 'failed')"
           )

    create constraint(
             :participation_email_deliveries,
             :participation_email_deliveries_event_version_positive,
             check: "event_version > 0"
           )
  end
end
