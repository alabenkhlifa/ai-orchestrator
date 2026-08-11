defmodule SddOrchestrator.Repo.Migrations.CreateRepositoryKitPackages do
  use Ecto.Migration

  def up do
    create table(:repository_kit_packages, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :source, :string, null: false
      add :publisher, :string, null: false
      add :version, :string, null: false
      add :digest, :string, null: false
      add :license, :string, null: false
      add :provenance, :map, null: false
      add :file_manifest, :map, null: false
      add :supported_adapters, {:array, :string}, null: false
      add :required_permissions, {:array, :string}, null: false, default: []
      add :scripts, {:array, :string}, null: false, default: []

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:repository_kit_packages, [:digest],
             name: :repository_kit_packages_digest_index
           )

    create unique_index(
             :repository_kit_packages,
             [:source, :publisher, :version],
             name: :repository_kit_packages_source_publisher_version_index
           )

    create index(:repository_kit_packages, [:source, :publisher])

    create constraint(:repository_kit_packages, :repository_kit_packages_digest_shape,
             check: "digest ~ '^[0-9a-f]{64}$'"
           )

    create constraint(:repository_kit_packages, :repository_kit_packages_provenance_shape,
             check:
               "provenance->>'ref_type' = 'commit' AND (provenance->>'ref') ~ '^([0-9a-f]{40}|[0-9a-f]{64})$'"
           )

    execute("""
    CREATE FUNCTION reject_repository_kit_package_update()
    RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'repository kit packages are immutable';
    END;
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE TRIGGER repository_kit_packages_immutable
    BEFORE UPDATE ON repository_kit_packages
    FOR EACH ROW EXECUTE FUNCTION reject_repository_kit_package_update()
    """)
  end

  def down do
    execute("DROP TRIGGER IF EXISTS repository_kit_packages_immutable ON repository_kit_packages")

    execute("DROP FUNCTION IF EXISTS reject_repository_kit_package_update()")
    drop table(:repository_kit_packages)
  end
end
