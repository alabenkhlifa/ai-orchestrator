defmodule SddOrchestrator.Repo.Migrations.AddPlanTypeToRepositoryKitChangePlans do
  use Ecto.Migration

  def up do
    alter table(:repository_kit_change_plans) do
      add :plan_type, :string, null: false, default: "install"
    end

    create constraint(
             :repository_kit_change_plans,
             :repository_kit_change_plans_plan_type_shape,
             check: "plan_type IN ('install', 'update')"
           )
  end

  def down do
    execute(
      "ALTER TABLE repository_kit_change_plans DROP CONSTRAINT repository_kit_change_plans_plan_type_shape"
    )

    alter table(:repository_kit_change_plans) do
      remove :plan_type
    end
  end
end
