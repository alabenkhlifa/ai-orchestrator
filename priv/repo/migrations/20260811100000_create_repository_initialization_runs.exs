defmodule SddOrchestrator.Repo.Migrations.CreateRepositoryInitializationRuns do
  use Ecto.Migration

  def change do
    create table(:repository_initialization_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :plan_id, references(:repository_initialization_plans, type: :binary_id), null: false

      # Pre-project data, matching `repository_initialization_plans`' own
      # convention: neither the device workspace nor the paired worker is a
      # foreign key into this database (both live outside it, matching that
      # table and `local_workers`).
      add :device_workspace_id, :binary_id, null: false
      add :worker_id, :binary_id, null: false

      # The InitializationManifest's own dispatch id (Task 1), kept here only
      # for traceability — never reused for anything functional.
      add :dispatch_id, :string, null: false

      # A caller-supplied stable key so retrying the same run request never
      # starts two staging builds.
      add :idempotency_key, :string, null: false

      add :state, :string, null: false, default: "pending"

      # Frozen snapshot of the plan's kit choice at run creation — defense in
      # depth against a later plan mutation, even though `Plan`'s own
      # invalidation rules should already prevent that from mattering.
      add :kit_choice, :string, null: false

      add :kit_package_id,
          references(:repository_kit_packages, type: :binary_id, on_delete: :nilify_all)

      add :kit_package_digest, :string

      # Ordered typed activity events: `{"type", "occurred_at", "payload"}`,
      # matching `AgentAdapter.observe/2`'s own progress/evidence/failed
      # vocabulary (minus `blocked`, which does not apply to a fully
      # deterministic build).
      add :progress, :jsonb, null: false, default: fragment("'[]'::jsonb")

      add :failure_reason, :string
      add :cancel_requested_at, :utc_datetime
      add :started_at, :utc_datetime
      add :finished_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:repository_initialization_runs, [:plan_id])
    create index(:repository_initialization_runs, [:device_workspace_id])
    create index(:repository_initialization_runs, [:kit_package_id])
    create unique_index(:repository_initialization_runs, [:idempotency_key])

    create constraint(
             :repository_initialization_runs,
             :repository_initialization_runs_state_check,
             check: "state IN ('pending', 'running', 'completed', 'failed', 'canceled')"
           )

    create constraint(
             :repository_initialization_runs,
             :repository_initialization_runs_kit_choice_check,
             check: "kit_choice IN ('included', 'declined')"
           )

    create constraint(
             :repository_initialization_runs,
             :repository_initialization_runs_progress_array,
             check: "jsonb_typeof(progress) = 'array'"
           )
  end
end
