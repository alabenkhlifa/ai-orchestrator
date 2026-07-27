defmodule SddOrchestrator.Repo.Migrations.CreateHostedSessions do
  use Ecto.Migration

  def change do
    create table(:hosted_sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :token_digest, :binary, null: false
      add :user_agent_family, :string
      add :os_family, :string
      add :first_seen_at, :utc_datetime, null: false
      add :last_seen_at, :utc_datetime, null: false
      add :expires_at, :utc_datetime, null: false

      add :hosted_identity_id,
          references(:hosted_identities, type: :binary_id, on_delete: :delete_all),
          null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:hosted_sessions, [:token_digest])
    create index(:hosted_sessions, [:hosted_identity_id])
    create index(:hosted_sessions, [:expires_at])
  end
end
