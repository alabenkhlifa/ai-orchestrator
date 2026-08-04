defmodule SddOrchestrator.Repo.Migrations.CreateRepositoryAssessments do
  use Ecto.Migration

  def change do
    create table(:repository_assessments, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :repository_provider, :string, null: false
      add :repository_id, :string, null: false
      add :root, :text, null: false
      add :commit, :string, null: false
      add :scanner_contract_digest, :string, null: false
      add :disclosure_digest, :string, null: false
      add :worker_ref, :binary_id, null: false
      add :state, :string, null: false
      add :boundary_confirmed_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:repository_assessments, [:project_id])
    create index(:repository_assessments, [:project_id, :state])

    create constraint(:repository_assessments, :repository_assessments_pending_state,
             check: "state = 'pending_scan'"
           )

    create constraint(:repository_assessments, :repository_assessments_commit_shape,
             check: "commit ~ '^([0-9a-f]{40}|[0-9a-f]{64})$'"
           )

    create constraint(:repository_assessments, :repository_assessments_digest_shape,
             check:
               "scanner_contract_digest ~ '^[0-9a-f]{64}$' AND disclosure_digest ~ '^[0-9a-f]{64}$'"
           )
  end
end
