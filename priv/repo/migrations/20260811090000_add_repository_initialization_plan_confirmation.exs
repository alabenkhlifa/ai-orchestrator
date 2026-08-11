defmodule SddOrchestrator.Repo.Migrations.AddRepositoryInitializationPlanConfirmation do
  use Ecto.Migration

  def change do
    alter table(:repository_initialization_plans) do
      # The permanent kit is proposed by default (business rules); the user
      # may decline it before confirmation.
      add :kit_choice, :string, null: false, default: "included"

      # Set only when kit_choice == "included" and a default kit could be
      # resolved from the catalog; nil when declined or when no kit package
      # exists yet. Nullified (not cascade-deleted) if the referenced
      # package were ever removed, since a plan must survive that.
      add :kit_package_id,
          references(:repository_kit_packages, type: :binary_id, on_delete: :nilify_all)

      # A snapshot of the chosen package's digest at selection time — part of
      # the confirmation binding and re-checked at confirm time to catch a
      # kit that changed underneath the user between render and confirm.
      add :kit_package_digest, :string

      # Set once the processing-boundary disclosure (AC-05) has been shown.
      add :disclosure_version, :integer

      add :confirmed_at, :utc_datetime
      add :confirmation_digest, :string
    end

    create index(:repository_initialization_plans, [:kit_package_id])

    create constraint(
             :repository_initialization_plans,
             :repository_initialization_plans_kit_choice_check,
             check: "kit_choice IN ('included', 'declined')"
           )

    create constraint(
             :repository_initialization_plans,
             :repository_initialization_plans_confirmation_digest_check,
             check: "confirmation_digest IS NULL OR confirmation_digest ~ '^[0-9a-f]{64}$'"
           )
  end
end
