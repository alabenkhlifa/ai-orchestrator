defmodule SddOrchestrator.Repo.Migrations.CreateAIRuntimeSessions do
  use Ecto.Migration

  def up do
    create table(:ai_runtime_sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :connection_id,
          references(:personal_ai_connections, type: :binary_id, on_delete: :delete_all),
          null: false

      add :consumer_kind, :string, null: false
      add :consumer_ref, :string, null: false
      add :provider, :string, null: false
      add :authentication_mode, :string, null: false
      add :model, :string, null: false
      add :reasoning_effort, :string, null: false
      add :configuration_version, :integer, null: false, default: 1
      add :catalog_snapshot_ref, :binary_id, null: false
      add :catalog_source, :string, null: false
      add :catalog_source_method, :string, null: false
      add :catalog_source_version, :string, null: false
      add :catalog_retrieved_at, :utc_datetime, null: false
      add :catalog_expires_at, :utc_datetime, null: false
      add :opt_ins, :map, null: false
      add :spending_ceiling_amount, :decimal, precision: 12, scale: 4
      add :spending_ceiling_currency, :string
      add :pinned_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:ai_runtime_sessions, [:account_id, :connection_id])

    create unique_index(
             :ai_runtime_sessions,
             [:account_id, :consumer_kind, :consumer_ref],
             name: :ai_runtime_sessions_consumer_index
           )

    create constraint(:ai_runtime_sessions, :ai_runtime_sessions_consumer_kind_check,
             check: "consumer_kind IN ('support_assistant', 'working_agent')"
           )

    create constraint(:ai_runtime_sessions, :ai_runtime_sessions_consumer_ref_check,
             check:
               "consumer_ref = btrim(consumer_ref) AND char_length(consumer_ref) BETWEEN 1 AND 255"
           )

    create constraint(:ai_runtime_sessions, :ai_runtime_sessions_provider_check,
             check: "provider IN ('openai_codex')"
           )

    create constraint(:ai_runtime_sessions, :ai_runtime_sessions_authentication_mode_check,
             check: "authentication_mode IN ('chatgpt', 'api_key')"
           )

    create constraint(:ai_runtime_sessions, :ai_runtime_sessions_selection_check,
             check:
               "char_length(model) BETWEEN 1 AND 255 AND char_length(reasoning_effort) BETWEEN 1 AND 64"
           )

    create constraint(:ai_runtime_sessions, :ai_runtime_sessions_configuration_version_check,
             check: "configuration_version >= 1"
           )

    create constraint(:ai_runtime_sessions, :ai_runtime_sessions_catalog_source_check,
             check: "catalog_source = 'official_client'"
           )

    create constraint(:ai_runtime_sessions, :ai_runtime_sessions_catalog_expiry_check,
             check: "catalog_expires_at > catalog_retrieved_at"
           )

    create constraint(:ai_runtime_sessions, :ai_runtime_sessions_opt_ins_check,
             check:
               "jsonb_typeof(opt_ins) = 'object' AND opt_ins ? 'items' AND jsonb_typeof(opt_ins->'items') = 'array'"
           )

    create constraint(:ai_runtime_sessions, :ai_runtime_sessions_spending_ceiling_check,
             check: """
             (authentication_mode = 'api_key'
               AND spending_ceiling_amount IS NOT NULL
               AND spending_ceiling_amount > 0
               AND spending_ceiling_currency ~ '^[A-Z]{3}$')
             OR (authentication_mode <> 'api_key'
               AND spending_ceiling_amount IS NULL
               AND spending_ceiling_currency IS NULL)
             """
           )

    execute("""
    CREATE FUNCTION prevent_ai_runtime_session_reconfiguration()
    RETURNS trigger AS $$
    BEGIN
      IF NEW.account_id IS DISTINCT FROM OLD.account_id
         OR NEW.connection_id IS DISTINCT FROM OLD.connection_id
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
         OR NEW.pinned_at IS DISTINCT FROM OLD.pinned_at THEN
        RAISE EXCEPTION USING
          ERRCODE = '23514',
          CONSTRAINT = 'ai_runtime_sessions_immutable_configuration',
          MESSAGE = 'AI runtime session configuration is immutable';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER ai_runtime_sessions_immutable_configuration_trigger
    BEFORE UPDATE ON ai_runtime_sessions
    FOR EACH ROW EXECUTE FUNCTION prevent_ai_runtime_session_reconfiguration();
    """)
  end

  def down do
    execute("""
    DROP TRIGGER IF EXISTS ai_runtime_sessions_immutable_configuration_trigger
      ON ai_runtime_sessions;
    """)

    execute("""
    DROP FUNCTION IF EXISTS prevent_ai_runtime_session_reconfiguration();
    """)

    drop table(:ai_runtime_sessions)
  end
end
