defmodule SddOrchestrator.Repo.Migrations.CreateMagicLinkAttempts do
  use Ecto.Migration

  def change do
    create table(:magic_link_attempts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :token_digest, :binary, null: false
      add :token_salt, :binary, null: false
      add :email_key, :string, null: false
      add :delivery_email, :string, null: false
      add :delivery_status, :string, null: false, default: "pending"
      add :expires_at, :utc_datetime, null: false
      add :consumed_at, :utc_datetime
      add :invalidated_at, :utc_datetime
      add :failure_code, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:magic_link_attempts, [:token_digest])
    create index(:magic_link_attempts, [:email_key])
    create index(:magic_link_attempts, [:expires_at])

    create unique_index(:magic_link_attempts, [:email_key],
             name: :magic_link_attempts_one_active_email_index,
             where: "consumed_at IS NULL AND invalidated_at IS NULL"
           )

    create constraint(:magic_link_attempts, :magic_link_attempts_delivery_status_check,
             check: "delivery_status IN ('pending', 'sent', 'failed')"
           )
  end
end
