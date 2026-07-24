defmodule SddOrchestrator.Repo.Migrations.CreateAccountsAndSessions do
  use Ecto.Migration

  def change do
    create table(:accounts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :state, :string, null: false, default: "active"

      timestamps(type: :utc_datetime)
    end

    create table(:github_identities, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :github_user_id, :bigint, null: false
      add :login, :string, null: false
      add :avatar_url, :string

      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime)
    end

    # One stable workspace per GitHub identity; a GitHub user maps to one account.
    create unique_index(:github_identities, [:github_user_id])
    create unique_index(:github_identities, [:account_id])

    create table(:github_credentials, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :access_token, :binary, null: false
      add :refresh_token, :binary
      add :token_expires_at, :utc_datetime
      add :scopes, :string
      add :revoked_at, :utc_datetime

      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:github_credentials, [:account_id])

    create table(:github_authorization_attempts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :state_digest, :string, null: false
      add :browser_nonce_digest, :string, null: false
      add :pkce_verifier, :binary, null: false
      add :return_to, :string
      add :expires_at, :utc_datetime, null: false
      add :consumed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:github_authorization_attempts, [:state_digest])
    create index(:github_authorization_attempts, [:expires_at])

    create table(:application_sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :token_digest, :string, null: false
      add :idle_expires_at, :utc_datetime, null: false
      add :absolute_expires_at, :utc_datetime, null: false
      add :last_used_at, :utc_datetime
      add :revoked_at, :utc_datetime

      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:application_sessions, [:token_digest])
    create index(:application_sessions, [:account_id])
  end
end
