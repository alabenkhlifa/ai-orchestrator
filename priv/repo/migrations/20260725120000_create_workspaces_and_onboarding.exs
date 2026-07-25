defmodule SddOrchestrator.Repo.Migrations.CreateWorkspacesAndOnboarding do
  use Ecto.Migration

  def change do
    # One personal workspace per account: the ownership boundary for projects
    # and repository connections. The unique account_id makes get-or-create
    # race-safe.
    create table(:personal_workspaces, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:personal_workspaces, [:account_id])

    # Minimal project read-model owned by this task so the catalog can list and
    # route on real rows. The registration transaction, canonical name key and
    # uniqueness, storage mode, lifecycle state, and repository connection are
    # added by the project-confirmation task, which extends this table.
    create table(:projects, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false

      add :workspace_id,
          references(:personal_workspaces, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:projects, [:workspace_id])

    # Short-lived server-side onboarding workflow state. This task owns the
    # schema, initial state, and idempotency key; the selected repository
    # (repository picker), storage mode and device-setup return state (storage
    # step), and consumption (registration) are written by later tasks.
    create table(:project_onboarding_attempts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :idempotency_key, :string, null: false
      add :status, :string, null: false, default: "started"
      add :selected_repository, :map
      add :storage_mode, :string
      add :device_setup, :map
      add :expires_at, :utc_datetime, null: false
      add :consumed_at, :utc_datetime

      add :workspace_id,
          references(:personal_workspaces, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:project_onboarding_attempts, [:idempotency_key])
    create index(:project_onboarding_attempts, [:workspace_id])
    # Supports the retention pruner that deletes abandoned attempts.
    create index(:project_onboarding_attempts, [:expires_at])
  end
end
