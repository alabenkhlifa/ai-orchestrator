defmodule SddOrchestrator.Repo.Migrations.CreateRepositoryInitializationPlans do
  use Ecto.Migration

  def change do
    create table(:repository_initialization_plans, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # Pre-project data: neither identifier is a foreign key. The device
      # workspace lives outside this database (matches `local_workers` and
      # `pairing_attempts`), and the account is only ever an opportunistic,
      # nullable soft-link — the empty-repository entry, eligibility check,
      # and plan stay accountless like local onboarding, while the account is
      # set only when a signed-in account initiated the plan (needed to pin
      # a support-assistant runtime session for a guided-question turn).
      add :device_workspace_id, :binary_id, null: false
      add :account_id, :binary_id

      # Opaque token issued at eligibility time; never the real selected path.
      add :target_reference, :string, null: false

      add :version, :integer, null: false, default: 1
      add :current_field, :string, null: false, default: "purpose"

      add :purpose, :text
      add :users, :text
      add :first_outcome, :text
      add :constraints, :text
      add :technical_foundation, :map, null: false, default: %{}

      add :eligibility, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:repository_initialization_plans, [:device_workspace_id])
    create index(:repository_initialization_plans, [:account_id])

    create constraint(
             :repository_initialization_plans,
             :repository_initialization_plans_current_field_check,
             check:
               "current_field IN ('purpose', 'users', 'first_outcome', 'constraints', 'technical_foundation', 'ready')"
           )

    create constraint(
             :repository_initialization_plans,
             :repository_initialization_plans_eligibility_check,
             check: "eligibility IN ('empty_directory', 'unborn_repository')"
           )

    create constraint(
             :repository_initialization_plans,
             :repository_initialization_plans_version_positive,
             check: "version > 0"
           )

    create constraint(
             :repository_initialization_plans,
             :repository_initialization_plans_target_reference_check,
             check: "char_length(target_reference) BETWEEN 1 AND 255"
           )
  end
end
