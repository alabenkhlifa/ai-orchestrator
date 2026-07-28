defmodule SddOrchestrator.Repo.Migrations.CreateWorkspaceMergeRecords do
  use Ecto.Migration

  @moduledoc """
  The minimal, inaccessible post-commit evidence that replaces an absorbed
  workspace.

  It holds exactly the six approved fields — merge event id, source workspace id,
  surviving workspace id, status, completion time, and deletion deadline — and
  nothing else: no project identifiers or content, repository metadata, email,
  credentials, sessions, worker secrets, conflict details, membership data, or
  analytics join keys. It carries no foreign keys, so deleting the absorbed
  workspace and account leaves it intact, and it is deleted at its deadline by the
  retention pruner. Its lawful basis and exact retention require the release-gate
  privacy or legal review.
  """

  def change do
    create table(:workspace_merge_records, primary_key: false) do
      add :merge_event_id, :binary_id, primary_key: true
      add :source_workspace_id, :binary_id, null: false
      add :surviving_workspace_id, :binary_id, null: false
      add :status, :string, null: false
      add :completed_at, :utc_datetime, null: false
      add :delete_after, :utc_datetime, null: false
    end

    create index(:workspace_merge_records, [:surviving_workspace_id])
    create index(:workspace_merge_records, [:delete_after])

    create constraint(:workspace_merge_records, :workspace_merge_records_status_check,
             check: "status IN ('completed')"
           )
  end
end
