defmodule SddOrchestrator.Repo.Migrations.DeferRepositoryConnectionWorkspaceFk do
  use Ecto.Migration

  @moduledoc """
  Makes the connection-follows-project composite foreign key deferrable.

  `repository_connections (project_id, workspace_id)` references
  `projects (id, workspace_id)`. An identity merge moves a project and its
  connection to the surviving workspace together; with an immediate check neither
  update order is valid, because one table is transiently inconsistent with the
  other. `DEFERRABLE INITIALLY DEFERRED` moves the check to transaction commit,
  by which point both rows name the surviving workspace. The integrity guarantee
  is unchanged for every non-merge write.
  """

  def up do
    execute(
      "ALTER TABLE repository_connections DROP CONSTRAINT repository_connections_project_workspace_fkey"
    )

    execute("""
    ALTER TABLE repository_connections
    ADD CONSTRAINT repository_connections_project_workspace_fkey
    FOREIGN KEY (project_id, workspace_id)
    REFERENCES projects (id, workspace_id)
    ON DELETE CASCADE
    DEFERRABLE INITIALLY DEFERRED
    """)
  end

  def down do
    execute(
      "ALTER TABLE repository_connections DROP CONSTRAINT repository_connections_project_workspace_fkey"
    )

    execute("""
    ALTER TABLE repository_connections
    ADD CONSTRAINT repository_connections_project_workspace_fkey
    FOREIGN KEY (project_id, workspace_id)
    REFERENCES projects (id, workspace_id)
    ON DELETE CASCADE
    """)
  end
end
