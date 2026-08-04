defmodule SddOrchestrator.Repo.Migrations.AddPersonalAIConnectionRevocationLifecycle do
  use Ecto.Migration

  def up do
    alter table(:personal_ai_connections) do
      add :credential_removal_attempts, :integer, null: false, default: 0
      add :credential_removal_attempted_at, :utc_datetime
      add :credential_removal_failure_reason, :string
      add :credential_removal_result, :string
      add :deletion_scheduled_at, :utc_datetime
    end

    create constraint(
             :personal_ai_connections,
             :personal_ai_connections_credential_removal_attempts_check,
             check: "credential_removal_attempts >= 0"
           )

    # Only typed reasons are storable. A raw provider or adapter error has no
    # value this column would accept.
    create constraint(
             :personal_ai_connections,
             :personal_ai_connections_credential_removal_reason_check,
             check: """
             credential_removal_failure_reason IS NULL
             OR credential_removal_failure_reason IN (
               'worker_unavailable', 'timeout', 'incompatible', 'invalid_request', 'invalid_response'
             )
             """
           )

    create constraint(
             :personal_ai_connections,
             :personal_ai_connections_credential_removal_result_check,
             check: """
             credential_removal_result IS NULL
             OR credential_removal_result IN ('removed', 'absent')
             """
           )

    # An acknowledged connection is terminal: it carries the bounded removal
    # outcome, has no outstanding failure reason, and already knows when its
    # opaque reference is deleted. Every other state carries none of those.
    create constraint(
             :personal_ai_connections,
             :personal_ai_connections_revocation_terminal_check,
             check: """
             (revocation_state = 'acknowledged'
               AND credential_removal_result IS NOT NULL
               AND deletion_scheduled_at IS NOT NULL
               AND credential_removal_failure_reason IS NULL)
             OR (revocation_state <> 'acknowledged'
               AND credential_removal_result IS NULL
               AND deletion_scheduled_at IS NULL)
             """
           )

    create constraint(
             :personal_ai_connections,
             :personal_ai_connections_credential_removal_attempt_check,
             check: """
             (revocation_state = 'active'
               AND credential_removal_attempts = 0
               AND credential_removal_attempted_at IS NULL
               AND credential_removal_failure_reason IS NULL)
             OR revocation_state <> 'active'
             """
           )

    create index(:personal_ai_connections, [:credential_removal_attempted_at],
             where: "revocation_state = 'requested'",
             name: :personal_ai_connections_pending_revocation_index
           )

    create index(:personal_ai_connections, [:deletion_scheduled_at],
             where: "deletion_scheduled_at IS NOT NULL",
             name: :personal_ai_connections_deletion_schedule_index
           )
  end

  def down do
    drop index(:personal_ai_connections, [:deletion_scheduled_at],
           name: :personal_ai_connections_deletion_schedule_index
         )

    drop index(:personal_ai_connections, [:credential_removal_attempted_at],
           name: :personal_ai_connections_pending_revocation_index
         )

    drop constraint(
           :personal_ai_connections,
           :personal_ai_connections_credential_removal_attempt_check
         )

    drop constraint(
           :personal_ai_connections,
           :personal_ai_connections_revocation_terminal_check
         )

    drop constraint(
           :personal_ai_connections,
           :personal_ai_connections_credential_removal_result_check
         )

    drop constraint(
           :personal_ai_connections,
           :personal_ai_connections_credential_removal_reason_check
         )

    drop constraint(
           :personal_ai_connections,
           :personal_ai_connections_credential_removal_attempts_check
         )

    alter table(:personal_ai_connections) do
      remove :deletion_scheduled_at
      remove :credential_removal_result
      remove :credential_removal_failure_reason
      remove :credential_removal_attempted_at
      remove :credential_removal_attempts
    end
  end
end
