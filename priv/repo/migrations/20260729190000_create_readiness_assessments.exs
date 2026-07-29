defmodule SddOrchestrator.Repo.Migrations.CreateReadinessAssessments do
  use Ecto.Migration

  def change do
    create table(:readiness_assessments, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :feature_id, references(:features, type: :binary_id, on_delete: :delete_all),
        null: false

      # The assessed specification belongs to the shared store, so it is
      # referenced by identity and digest. Readiness must never become a second
      # copy of the requirements it assessed.
      add :specification_id, :string, null: false
      add :revision_id, :string, null: false
      add :revision_digest, :string, null: false

      add :findings, :map, null: false, default: %{}
      add :dismissed_ids, {:array, :string}, null: false, default: []

      # Bumped on every replacement so a dismissal offered against a superseded
      # assessment is rejected rather than applied to different findings.
      add :version, :integer, null: false, default: 1
      add :assessed_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    # One current assessment per feature: a new evaluation replaces the old one
    # rather than accumulating a history of contradictory verdicts.
    create unique_index(:readiness_assessments, [:feature_id])
    create index(:readiness_assessments, [:project_id])

    create constraint(:readiness_assessments, :readiness_assessments_version_positive,
             check: "version > 0"
           )
  end
end
