defmodule SddOrchestrator.Repo.Migrations.CreateRepositoryInitializationResults do
  use Ecto.Migration

  def change do
    create table(:repository_initialization_results, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :plan_id, references(:repository_initialization_plans, type: :binary_id), null: false

      add :run_id, references(:repository_initialization_runs, type: :binary_id), null: false

      # The plan's own opaque token (`Plan.target_reference`) — the real
      # selected path never appears here either, matching AC-01's rule.
      add :target_reference, :string, null: false

      add :commit_sha, :string, null: false
      add :tree_digest, :string, null: false

      add :kit_choice, :string, null: false

      add :kit_package_id,
          references(:repository_kit_packages, type: :binary_id, on_delete: :nilify_all)

      add :kit_package_digest, :string

      # Typed required-check evidence bound to `commit_sha` — an empty list
      # today, matching the fixed skeleton's own empty `checks` list.
      add :check_evidence, :jsonb, null: false, default: fragment("'[]'::jsonb")

      add :completed_at, :utc_datetime, null: false

      # Task 6 (local-onboarding handoff) owns advancing this past "pending".
      add :onboarding_handoff_state, :string, null: false, default: "pending"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:repository_initialization_results, [:run_id])
    create index(:repository_initialization_results, [:plan_id])
    create index(:repository_initialization_results, [:kit_package_id])

    create constraint(
             :repository_initialization_results,
             :repository_initialization_results_kit_choice_check,
             check: "kit_choice IN ('included', 'declined')"
           )

    create constraint(
             :repository_initialization_results,
             :repository_initialization_results_handoff_state_check,
             check: "onboarding_handoff_state IN ('pending', 'completed')"
           )

    create constraint(
             :repository_initialization_results,
             :repository_initialization_results_check_evidence_array,
             check: "jsonb_typeof(check_evidence) = 'array'"
           )
  end
end
