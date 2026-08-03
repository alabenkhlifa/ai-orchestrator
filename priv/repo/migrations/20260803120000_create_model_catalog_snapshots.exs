defmodule SddOrchestrator.Repo.Migrations.CreateModelCatalogSnapshots do
  use Ecto.Migration

  def change do
    create table(:model_catalog_snapshots, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :connection_id,
          references(:personal_ai_connections, type: :binary_id, on_delete: :delete_all),
          null: false

      add :provider, :string, null: false
      add :status, :string, null: false
      add :source, :string, null: false
      add :source_method, :string, null: false
      add :source_version, :string, null: false
      add :retrieved_at, :utc_datetime, null: false
      add :expires_at, :utc_datetime, null: false
      add :models, :map, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:model_catalog_snapshots, [:account_id, :connection_id, :retrieved_at])
    create index(:model_catalog_snapshots, [:expires_at])

    create constraint(:model_catalog_snapshots, :model_catalog_snapshots_status_check,
             check: "status IN ('enumerated', 'enumeration_unsupported')"
           )

    create constraint(:model_catalog_snapshots, :model_catalog_snapshots_source_check,
             check: "source = 'official_client'"
           )

    create constraint(:model_catalog_snapshots, :model_catalog_snapshots_expiry_check,
             check: "expires_at > retrieved_at"
           )

    create constraint(:model_catalog_snapshots, :model_catalog_snapshots_models_check,
             check:
               "jsonb_typeof(models) = 'object' AND models ? 'items' AND jsonb_typeof(models->'items') = 'array'"
           )
  end
end
