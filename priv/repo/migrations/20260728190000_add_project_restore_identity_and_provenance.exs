defmodule SddOrchestrator.Repo.Migrations.AddProjectRestoreIdentityAndProvenance do
  use Ecto.Migration

  def up do
    alter table(:projects) do
      add :repository_provider, :string
      add :canonical_repository_id, :string
    end

    execute("""
    UPDATE projects AS project
    SET repository_provider = connection.provider,
        canonical_repository_id = connection.provider_repository_id::text
    FROM repository_connections AS connection
    WHERE connection.project_id = project.id
    """)

    create unique_index(
             :projects,
             [:workspace_id, :repository_provider, :canonical_repository_id],
             name: :projects_workspace_repository_identity_index
           )

    create constraint(:projects, :projects_repository_identity_shape,
             check:
               "(repository_provider IS NULL AND canonical_repository_id IS NULL) OR " <>
                 "(repository_provider IS NOT NULL AND canonical_repository_id IS NOT NULL)"
           )

    create table(:package_provenances, primary_key: false) do
      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        primary_key: true

      add :payload_schema_version, :integer, null: false
      add :restored_at, :utc_datetime, null: false
    end

    create constraint(:package_provenances, :package_provenances_schema_version_positive,
             check: "payload_schema_version > 0"
           )
  end

  def down do
    drop table(:package_provenances)
    drop constraint(:projects, :projects_repository_identity_shape)

    drop index(:projects, [:workspace_id, :repository_provider, :canonical_repository_id],
           name: :projects_workspace_repository_identity_index
         )

    alter table(:projects) do
      remove :canonical_repository_id
      remove :repository_provider
    end
  end
end
