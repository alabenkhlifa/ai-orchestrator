defmodule SddOrchestrator.Repo.Migrations.WidenRepositoryKitChangePlansPlanTypeToRemoval do
  use Ecto.Migration

  def up do
    execute(
      "ALTER TABLE repository_kit_change_plans DROP CONSTRAINT repository_kit_change_plans_plan_type_shape"
    )

    create constraint(
             :repository_kit_change_plans,
             :repository_kit_change_plans_plan_type_shape,
             check: "plan_type IN ('install', 'update', 'removal')"
           )
  end

  def down do
    execute(
      "ALTER TABLE repository_kit_change_plans DROP CONSTRAINT repository_kit_change_plans_plan_type_shape"
    )

    create constraint(
             :repository_kit_change_plans,
             :repository_kit_change_plans_plan_type_shape,
             check: "plan_type IN ('install', 'update')"
           )
  end
end
