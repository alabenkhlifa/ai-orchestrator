defmodule SddOrchestrator.Repo.Migrations.AllowUnboundPairingAttempts do
  use Ecto.Migration

  # specs/38-worker-initiated-pairing Task 1.
  #
  # A pairing attempt may now exist before anyone knows which device workspace
  # it belongs to, so an unpaired worker app can obtain a code without first
  # having the workspace identity that pairing is what establishes.
  #
  # Relaxing the column alone would make the invalid third state reachable: an
  # attempt that authorized a worker while belonging to no workspace. The check
  # constraint closes that in the same migration, so no moment exists where the
  # column is optional and nothing enforces the invariant.
  #
  # Every existing row already carries a workspace and is therefore already
  # valid under the constraint, so no backfill is needed and none is performed.
  def up do
    alter table(:pairing_attempts) do
      modify :device_workspace_id, :binary_id, null: true
    end

    create constraint(:pairing_attempts, :pairing_attempts_bound_before_use_check,
             check:
               "device_workspace_id IS NOT NULL OR (confirmed_at IS NULL AND worker_id IS NULL)"
           )
  end

  def down do
    drop constraint(:pairing_attempts, :pairing_attempts_bound_before_use_check)

    # An unbound attempt cannot satisfy the restored NOT NULL, and it authorized
    # nothing by construction, so discarding it loses no pairing anyone holds.
    execute "DELETE FROM pairing_attempts WHERE device_workspace_id IS NULL"

    alter table(:pairing_attempts) do
      modify :device_workspace_id, :binary_id, null: false
    end
  end
end
