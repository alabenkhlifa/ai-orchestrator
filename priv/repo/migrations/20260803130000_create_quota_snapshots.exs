defmodule SddOrchestrator.Repo.Migrations.CreateQuotaSnapshots do
  use Ecto.Migration

  def change do
    create unique_index(:personal_ai_connections, [:account_id, :id],
             name: :personal_ai_connections_account_id_id_index
           )

    create table(:quota_snapshots, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :connection_id, :binary_id, null: false

      add :provider, :string, null: false
      add :authentication_mode, :string, null: false
      add :status, :string, null: false
      add :source, :string, null: false
      add :source_methods, {:array, :string}, null: false, default: []
      add :source_version, :string, null: false
      add :retrieved_at, :utc_datetime, null: false
      add :expires_at, :utc_datetime, null: false
      add :buckets, :map, null: false
      add :reset_credits, :map
      add :token_activity, :map
      add :unknown_fields, {:array, :string}, null: false, default: []

      timestamps(type: :utc_datetime)
    end

    create index(:quota_snapshots, [:account_id, :connection_id, :retrieved_at])
    create index(:quota_snapshots, [:expires_at])

    create unique_index(:quota_snapshots, [:account_id, :connection_id],
             name: :quota_snapshots_account_connection_index
           )

    execute(
      """
      ALTER TABLE quota_snapshots
      ADD CONSTRAINT quota_snapshots_account_connection_fkey
      FOREIGN KEY (account_id, connection_id)
      REFERENCES personal_ai_connections(account_id, id)
      ON DELETE CASCADE
      """,
      """
      ALTER TABLE quota_snapshots
      DROP CONSTRAINT IF EXISTS quota_snapshots_account_connection_fkey
      """
    )

    create constraint(:quota_snapshots, :quota_snapshots_authentication_mode_check,
             check: "authentication_mode IN ('chatgpt', 'api_key')"
           )

    create constraint(:quota_snapshots, :quota_snapshots_status_check,
             check: "status IN ('reported', 'partial', 'unknown')"
           )

    create constraint(:quota_snapshots, :quota_snapshots_source_check,
             check: "source = 'official_client'"
           )

    create constraint(:quota_snapshots, :quota_snapshots_expiry_check,
             check: "expires_at > retrieved_at"
           )

    create constraint(:quota_snapshots, :quota_snapshots_buckets_check,
             check:
               "jsonb_typeof(buckets) = 'object' AND buckets ? 'items' AND jsonb_typeof(buckets->'items') = 'array'"
           )

    create constraint(:quota_snapshots, :quota_snapshots_api_key_unknown_check,
             check: """
             authentication_mode <> 'api_key'
             OR (
               status = 'unknown'
               AND cardinality(source_methods) = 0
               AND jsonb_array_length(buckets->'items') = 0
               AND reset_credits IS NULL
               AND token_activity IS NULL
               AND unknown_fields @> ARRAY['api_key_quota', 'api_key_billing']::varchar[]
             )
             """
           )
  end
end
