defmodule SddOrchestrator.Repo.Migrations.DeferRepositoryConnectionWorkspaceFk do
  use Ecto.Migration

  @moduledoc """
  Makes the connection-follows-project composite foreign key deferrable, while
  keeping it checked immediately by default.

  `repository_connections (project_id, workspace_id)` references
  `projects (id, workspace_id)`. An identity merge moves a project and its
  connection to the surviving workspace together; with an immediate check neither
  update order is valid, because one table is transiently inconsistent with the
  other. `DEFERRABLE INITIALLY IMMEDIATE` keeps statement-time rejection for every
  ordinary write (the boundary guarantee is unchanged), while the merge
  transaction alone opts into commit-time checking with
  `SET CONSTRAINTS ... DEFERRED`, by which point both rows name the surviving
  workspace.
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
    DEFERRABLE INITIALLY IMMEDIATE
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
