defmodule SddOrchestrator.Repo.Migrations.DetachAIRuntimeSessionConnection do
  # Removing a personal connection revokes its opaque reference. It does not end
  # the project's need to account for what already ran under the configuration
  # that connection funded, so the reference is detached from the pinned session
  # instead of destroying the session with it.
  #
  # The immutability trigger is narrowed to permit exactly that one transition: a
  # present reference may become absent, and nothing else about a pinned
  # configuration may ever change.
  use Ecto.Migration

  def up do
    execute("""
    ALTER TABLE ai_runtime_sessions
      DROP CONSTRAINT ai_runtime_sessions_connection_id_fkey
    """)

    execute("ALTER TABLE ai_runtime_sessions ALTER COLUMN connection_id DROP NOT NULL")

    execute("""
    ALTER TABLE ai_runtime_sessions
      ADD CONSTRAINT ai_runtime_sessions_connection_id_fkey
      FOREIGN KEY (connection_id) REFERENCES personal_ai_connections(id)
      ON DELETE SET NULL
    """)

    execute(
      reconfiguration_guard("""
      OR (NEW.connection_id IS DISTINCT FROM OLD.connection_id
          AND NEW.connection_id IS NOT NULL)
      """)
    )
  end

  def down do
    execute("DELETE FROM ai_runtime_sessions WHERE connection_id IS NULL")

    execute("""
    ALTER TABLE ai_runtime_sessions
      DROP CONSTRAINT ai_runtime_sessions_connection_id_fkey
    """)

    execute("ALTER TABLE ai_runtime_sessions ALTER COLUMN connection_id SET NOT NULL")

    execute("""
    ALTER TABLE ai_runtime_sessions
      ADD CONSTRAINT ai_runtime_sessions_connection_id_fkey
      FOREIGN KEY (connection_id) REFERENCES personal_ai_connections(id)
      ON DELETE CASCADE
    """)

    execute(reconfiguration_guard("OR NEW.connection_id IS DISTINCT FROM OLD.connection_id"))
  end

  defp reconfiguration_guard(connection_clause) do
    """
    CREATE OR REPLACE FUNCTION prevent_ai_runtime_session_reconfiguration()
    RETURNS trigger AS $$
    BEGIN
      IF NEW.account_id IS DISTINCT FROM OLD.account_id
         OR NEW.consumer_kind IS DISTINCT FROM OLD.consumer_kind
         OR NEW.consumer_ref IS DISTINCT FROM OLD.consumer_ref
         OR NEW.provider IS DISTINCT FROM OLD.provider
         OR NEW.authentication_mode IS DISTINCT FROM OLD.authentication_mode
         OR NEW.model IS DISTINCT FROM OLD.model
         OR NEW.reasoning_effort IS DISTINCT FROM OLD.reasoning_effort
         OR NEW.configuration_version IS DISTINCT FROM OLD.configuration_version
         OR NEW.catalog_snapshot_ref IS DISTINCT FROM OLD.catalog_snapshot_ref
         OR NEW.catalog_source IS DISTINCT FROM OLD.catalog_source
         OR NEW.catalog_source_method IS DISTINCT FROM OLD.catalog_source_method
         OR NEW.catalog_source_version IS DISTINCT FROM OLD.catalog_source_version
         OR NEW.catalog_retrieved_at IS DISTINCT FROM OLD.catalog_retrieved_at
         OR NEW.catalog_expires_at IS DISTINCT FROM OLD.catalog_expires_at
         OR NEW.opt_ins IS DISTINCT FROM OLD.opt_ins
         OR NEW.spending_ceiling_amount IS DISTINCT FROM OLD.spending_ceiling_amount
         OR NEW.spending_ceiling_currency IS DISTINCT FROM OLD.spending_ceiling_currency
         OR NEW.pinned_at IS DISTINCT FROM OLD.pinned_at
         #{connection_clause} THEN
        RAISE EXCEPTION USING
          ERRCODE = '23514',
          CONSTRAINT = 'ai_runtime_sessions_immutable_configuration',
          MESSAGE = 'AI runtime session configuration is immutable';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """
  end
end
