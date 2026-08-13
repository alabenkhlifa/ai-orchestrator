defmodule SddOrchestrator.Repo.Migrations.CreateProjectContextProjections do
  use Ecto.Migration

  def change do
    create table(:project_context_projections, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      # A deterministic digest of `content`, so an unchanged rebuild is
      # provably idempotent and a later task can cite the exact assembled
      # context a turn read from without re-reading every source it covers.
      add :context_version, :string, null: false

      # Minimized current project metadata, specification identity and
      # revision references, board state, recent run status, and accepted
      # evidence only. No specification document body, repository path,
      # source, source index, prior revision, or full run log ever belongs
      # here — see `ProjectContextProjection`'s moduledoc.
      add :content, :map, null: false

      add :refreshed_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    # One replaceable projection per project: a rebuild replaces the single
    # current row rather than accumulating a history of stale snapshots.
    create unique_index(:project_context_projections, [:project_id])
  end
end
