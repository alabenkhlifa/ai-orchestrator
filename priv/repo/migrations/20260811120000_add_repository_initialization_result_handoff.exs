defmodule SddOrchestrator.Repo.Migrations.AddRepositoryInitializationResultHandoff do
  use Ecto.Migration

  # No `references()`: device projects and device specifications live in the
  # worker-owned device-local store, never in hosted PostgreSQL (see
  # `lib/sdd_orchestrator/projects.ex`'s own "device project and connection
  # rows are never written to hosted PostgreSQL" comment) — matching how
  # `Run`/`Result` already treat `device_workspace_id`/`worker_id` as plain
  # `:binary_id` columns with no foreign key.
  def change do
    alter table(:repository_initialization_results) do
      add :project_id, :binary_id
      add :specification_id, :binary_id
    end
  end
end
