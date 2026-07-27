defmodule SddOrchestrator.Repo.Migrations.CreateLocalWorkerPairing do
  use Ecto.Migration

  # Worker authorization metadata is a hosted control-plane concern: the control
  # plane must verify inbound worker connections. These tables hold only pairing
  # and authorization metadata keyed by an opaque device-workspace id (no foreign
  # key to `workspaces`, since accountless device roots are not hosted rows) and
  # never device-authoritative project data.
  def change do
    create table(:local_workers, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :device_workspace_id, :binary_id, null: false
      add :credential_digest, :binary, null: false
      add :credential_salt, :binary, null: false
      add :os_family, :string
      add :os_major, :string
      add :app_version, :string
      add :protocol_version, :string
      add :state, :string, null: false, default: "active"
      add :last_seen_at, :utc_datetime
      add :revoked_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:local_workers, [:device_workspace_id])

    create constraint(:local_workers, :local_workers_state_check,
             check: "state IN ('active', 'revoked')"
           )

    create table(:pairing_attempts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :device_workspace_id, :binary_id, null: false
      add :code_digest, :binary, null: false
      add :code_salt, :binary, null: false
      add :expires_at, :utc_datetime, null: false
      add :confirmed_at, :utc_datetime
      add :canceled_at, :utc_datetime

      add :worker_id, references(:local_workers, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:pairing_attempts, [:device_workspace_id])
  end
end
