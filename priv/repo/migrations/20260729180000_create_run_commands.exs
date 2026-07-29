defmodule SddOrchestrator.Repo.Migrations.CreateRunCommands do
  use Ecto.Migration

  def change do
    create table(:run_commands, primary_key: false) do
      # The stable command ID is supplied by the enqueueing transaction, not
      # generated here: that is what makes re-enqueueing the same instruction
      # return the recorded result instead of starting a second process.
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :run_id, references(:agent_runs, type: :binary_id, on_delete: :delete_all), null: false
      add :attempt_id, references(:run_attempts, type: :binary_id, on_delete: :nilify_all)

      add :operation, :string, null: false
      add :expected_state_version, :integer, null: false
      add :manifest_digest, :string

      # Backoff is scheduling, not sleeping: a retry is a command that is not
      # due yet, so it survives a control-plane restart.
      add :due_at, :utc_datetime_usec, null: false

      add :state, :string, null: false, default: "pending"

      # The claim lease is what lets several dispatchers run without delivering
      # one command twice; an expired claim returns the command to the queue.
      add :claimed_by, :string
      add :claim_expires_at, :utc_datetime_usec

      add :delivery_count, :integer, null: false, default: 0
      add :delivered_at, :utc_datetime_usec
      add :acknowledged_at, :utc_datetime_usec

      # The recorded outcome a duplicate enqueue or redelivery replays.
      add :result, :map
      add :failure_code, :string

      timestamps(type: :utc_datetime_usec)
    end

    create index(:run_commands, [:run_id])
    create index(:run_commands, [:attempt_id])
    create index(:run_commands, [:project_id])

    # The dispatcher's claim query: due, unclaimed, in order.
    create index(:run_commands, [:state, :due_at])

    create constraint(:run_commands, :run_commands_operation_allowed,
             check: "operation IN ('start', 'resume', 'retry', 'cancel', 'reconcile')"
           )

    create constraint(:run_commands, :run_commands_state_allowed,
             check: """
             state IN ('pending', 'claimed', 'delivered', 'acknowledged', 'failed')
             """
           )

    create constraint(:run_commands, :run_commands_delivery_count_not_negative,
             check: "delivery_count >= 0"
           )

    create constraint(:run_commands, :run_commands_expected_version_positive,
             check: "expected_state_version > 0"
           )

    create constraint(:run_commands, :run_commands_claim_pairing,
             check: """
             (claimed_by IS NULL AND claim_expires_at IS NULL)
               OR (claimed_by IS NOT NULL AND claim_expires_at IS NOT NULL)
             """
           )

    # An execution command must name the manifest it executes; a control command
    # has nothing to execute and must not pretend to.
    create constraint(:run_commands, :run_commands_manifest_placement,
             check: """
             (operation IN ('start', 'resume', 'retry') AND manifest_digest IS NOT NULL)
               OR (operation IN ('cancel', 'reconcile') AND manifest_digest IS NULL)
             """
           )
  end
end
