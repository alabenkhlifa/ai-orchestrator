defmodule SddOrchestrator.Repo.Migrations.IntroduceCommonWorkspaceBoundary do
  use Ecto.Migration

  def up do
    # The existing personal-workspace table already carries the stable ownership
    # ids referenced by projects, onboarding attempts, and connections. Rename it
    # into the common root so PostgreSQL preserves every row and foreign key.
    rename table(:personal_workspaces), to: table(:workspaces)

    execute("""
    ALTER TABLE workspaces
    RENAME CONSTRAINT personal_workspaces_pkey TO workspaces_pkey
    """)

    drop unique_index(:workspaces, [:account_id], name: :personal_workspaces_account_id_index)

    drop constraint(:workspaces, :personal_workspaces_account_id_fkey)

    alter table(:workspaces) do
      add :kind, :string, null: false, default: "hosted"
    end

    create constraint(:workspaces, :workspaces_hosted_kind_only, check: "kind = 'hosted'")

    create unique_index(:workspaces, [:id, :kind])

    # Recreate PersonalWorkspace as the one-to-one authenticated hosted profile.
    # Its primary key is also the common root id.
    create table(:personal_workspaces, primary_key: false) do
      add :id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        primary_key: true

      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:personal_workspaces, [:account_id])

    execute("""
    INSERT INTO personal_workspaces (id, account_id, inserted_at, updated_at)
    SELECT id, account_id, inserted_at, updated_at
    FROM workspaces
    """)

    alter table(:workspaces) do
      remove :account_id
    end

    # A device-authoritative row in hosted PostgreSQL cannot be silently moved or
    # reclassified. Fail closed if legacy development data contains one.
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM projects WHERE storage_mode = 'device') THEN
        RAISE EXCEPTION
          'device-authoritative projects must be moved to device persistence before this migration';
      END IF;
    END
    $$;
    """)

    # Legacy catalog-only rows predate the explicit storage field. They already
    # belong to hosted personal workspaces, so their authoritative mode is hosted.
    execute("UPDATE projects SET storage_mode = 'hosted' WHERE storage_mode IS NULL")

    alter table(:projects) do
      modify :storage_mode, :string, null: false
    end

    # Enforce Project.storage_mode == Workspace.kind without persisting a second
    # mode-bearing storage-state row.
    execute("""
    ALTER TABLE projects
    ADD CONSTRAINT projects_workspace_storage_mode_fkey
    FOREIGN KEY (workspace_id, storage_mode)
    REFERENCES workspaces (id, kind)
    ON DELETE CASCADE
    """)

    # A repository connection must name the same common root as its project.
    create unique_index(:projects, [:id, :workspace_id])

    execute("""
    ALTER TABLE repository_connections
    ADD CONSTRAINT repository_connections_project_workspace_fkey
    FOREIGN KEY (project_id, workspace_id)
    REFERENCES projects (id, workspace_id)
    ON DELETE CASCADE
    """)
  end

  def down do
    execute("""
    ALTER TABLE repository_connections
    DROP CONSTRAINT IF EXISTS repository_connections_project_workspace_fkey
    """)

    drop unique_index(:projects, [:id, :workspace_id])

    execute("""
    ALTER TABLE projects
    DROP CONSTRAINT IF EXISTS projects_workspace_storage_mode_fkey
    """)

    alter table(:projects) do
      modify :storage_mode, :string, null: true
    end

    execute("ALTER TABLE workspaces ADD COLUMN account_id uuid")

    execute("""
    UPDATE workspaces AS w
    SET account_id = pw.account_id
    FROM personal_workspaces AS pw
    WHERE pw.id = w.id
    """)

    execute("ALTER TABLE workspaces ALTER COLUMN account_id SET NOT NULL")

    execute("""
    ALTER TABLE workspaces
    ADD CONSTRAINT personal_workspaces_account_id_fkey
    FOREIGN KEY (account_id)
    REFERENCES accounts (id)
    ON DELETE CASCADE
    """)

    drop table(:personal_workspaces)

    drop unique_index(:workspaces, [:id, :kind])
    drop constraint(:workspaces, :workspaces_hosted_kind_only)

    alter table(:workspaces) do
      remove :kind
    end

    create unique_index(:workspaces, [:account_id], name: :personal_workspaces_account_id_index)

    execute("""
    ALTER TABLE workspaces
    RENAME CONSTRAINT workspaces_pkey TO personal_workspaces_pkey
    """)

    rename table(:workspaces), to: table(:personal_workspaces)
  end
end
