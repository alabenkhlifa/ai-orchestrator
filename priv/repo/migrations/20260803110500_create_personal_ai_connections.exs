defmodule SddOrchestrator.Repo.Migrations.CreatePersonalAIConnections do
  use Ecto.Migration

  def up do
    create table(:personal_ai_connections, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :worker_id, references(:local_workers, type: :binary_id, on_delete: :restrict),
        null: false

      add :worker_profile_ref, :string, null: false
      add :label, :string, null: false
      add :provider, :string, null: false
      add :authentication_mode, :string, null: false
      add :availability, :string, null: false
      add :adapter_compatibility_version, :string, null: false
      add :revocation_state, :string, null: false, default: "active"
      add :revocation_requested_at, :utc_datetime
      add :revocation_acknowledged_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:personal_ai_connections, [:account_id])

    create unique_index(
             :personal_ai_connections,
             [:account_id, "lower(btrim(label))"],
             name: :personal_ai_connections_account_label_index
           )

    create unique_index(
             :personal_ai_connections,
             [:worker_id, :worker_profile_ref],
             name: :personal_ai_connections_worker_profile_index
           )

    create constraint(:personal_ai_connections, :personal_ai_connections_label_check,
             check: "label = btrim(label) AND char_length(label) BETWEEN 1 AND 100"
           )

    create constraint(
             :personal_ai_connections,
             :personal_ai_connections_worker_profile_ref_check,
             check: "char_length(worker_profile_ref) BETWEEN 1 AND 255"
           )

    create constraint(
             :personal_ai_connections,
             :personal_ai_connections_adapter_version_check,
             check: "char_length(adapter_compatibility_version) BETWEEN 1 AND 100"
           )

    create constraint(:personal_ai_connections, :personal_ai_connections_provider_check,
             check: "provider IN ('openai_codex')"
           )

    create constraint(
             :personal_ai_connections,
             :personal_ai_connections_authentication_mode_check,
             check: "authentication_mode IN ('chatgpt', 'api_key')"
           )

    create constraint(:personal_ai_connections, :personal_ai_connections_availability_check,
             check: "availability IN ('available', 'unavailable', 'incompatible')"
           )

    create constraint(:personal_ai_connections, :personal_ai_connections_revocation_state_check,
             check: "revocation_state IN ('active', 'requested', 'acknowledged')"
           )

    create constraint(
             :personal_ai_connections,
             :personal_ai_connections_revocation_timestamps_check,
             check: """
             (revocation_state = 'active' AND revocation_requested_at IS NULL AND revocation_acknowledged_at IS NULL)
             OR (revocation_state = 'requested' AND revocation_requested_at IS NOT NULL AND revocation_acknowledged_at IS NULL)
             OR (revocation_state = 'acknowledged' AND revocation_requested_at IS NOT NULL AND revocation_acknowledged_at IS NOT NULL)
             """
           )

    execute("""
    CREATE FUNCTION prevent_personal_ai_connection_rebinding()
    RETURNS trigger AS $$
    BEGIN
      IF NEW.account_id IS DISTINCT FROM OLD.account_id
         OR NEW.worker_id IS DISTINCT FROM OLD.worker_id
         OR NEW.worker_profile_ref IS DISTINCT FROM OLD.worker_profile_ref
         OR NEW.provider IS DISTINCT FROM OLD.provider
         OR NEW.authentication_mode IS DISTINCT FROM OLD.authentication_mode THEN
        RAISE EXCEPTION USING
          ERRCODE = '23514',
          CONSTRAINT = 'personal_ai_connections_immutable_binding',
          MESSAGE = 'personal AI connection binding is immutable';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER personal_ai_connections_immutable_binding_trigger
    BEFORE UPDATE ON personal_ai_connections
    FOR EACH ROW EXECUTE FUNCTION prevent_personal_ai_connection_rebinding();
    """)
  end

  def down do
    execute("""
    DROP TRIGGER IF EXISTS personal_ai_connections_immutable_binding_trigger
      ON personal_ai_connections;
    """)

    execute("""
    DROP FUNCTION IF EXISTS prevent_personal_ai_connection_rebinding();
    """)

    drop table(:personal_ai_connections)
  end
end
