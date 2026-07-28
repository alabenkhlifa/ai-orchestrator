defmodule SddOrchestrator.Repo.Migrations.CreateImportAttempts do
  use Ecto.Migration

  def change do
    create table(:import_attempts, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all)
      add :device_workspace_id, :binary_id
      add :destination, :string, null: false
      add :status, :string, null: false
      add :encrypted_package, :binary, null: false
      add :expires_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:import_attempts, [:workspace_id])
    create index(:import_attempts, [:device_workspace_id])
    create index(:import_attempts, [:inserted_at])

    create constraint(:import_attempts, :import_attempt_authority_shape,
             check: """
             (destination = 'hosted' AND workspace_id IS NOT NULL AND device_workspace_id IS NULL)
             OR
             (destination = 'device' AND workspace_id IS NULL AND device_workspace_id IS NOT NULL)
             """
           )

    create constraint(:import_attempts, :import_attempt_status,
             check: "status IN ('uploaded', 'validating')"
           )
  end
end
