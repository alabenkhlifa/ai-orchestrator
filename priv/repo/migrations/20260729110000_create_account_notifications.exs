defmodule SddOrchestrator.Repo.Migrations.CreateAccountNotifications do
  use Ecto.Migration

  def change do
    create table(:account_notifications, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :event_type, :string, null: false
      add :subject_ref, :string, null: false
      add :event_version, :integer, null: false, default: 1
      add :title, :string, null: false
      add :body, :string, null: false
      add :project_label, :string
      add :actor_label, :string
      add :link_path, :string, null: false
      add :occurred_at, :utc_datetime, null: false
      add :read_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    # One record per recipient, event type, subject, and subject state version, so
    # an at-least-once projector replay cannot create a duplicate notification.
    create unique_index(
             :account_notifications,
             [:account_id, :event_type, :subject_ref, :event_version],
             name: :account_notifications_event_recipient_index
           )

    create index(:account_notifications, [:account_id, :occurred_at])

    create constraint(:account_notifications, :account_notifications_event_version_positive,
             check: "event_version > 0"
           )

    create constraint(:account_notifications, :account_notifications_link_path_relative,
             check: "link_path LIKE '/%' AND link_path NOT LIKE '//%'"
           )
  end
end
