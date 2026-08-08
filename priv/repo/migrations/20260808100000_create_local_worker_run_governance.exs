defmodule SddOrchestrator.Repo.Migrations.CreateLocalWorkerRunGovernance do
  use Ecto.Migration

  def change do
    create table(:local_worker_run_governance, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :run_id, references(:agent_runs, type: :binary_id, on_delete: :delete_all), null: false

      add :session_id,
          references(:ai_runtime_sessions, type: :binary_id, on_delete: :delete_all),
          null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:local_worker_run_governance, [:run_id],
             name: :local_worker_run_governance_run_index
           )

    create index(:local_worker_run_governance, [:session_id])
  end
end
