defmodule SddOrchestrator.Repo.Migrations.WidenRepositoryKitInstallationsStateToRemoved do
  use Ecto.Migration

  def up do
    execute(
      "ALTER TABLE repository_kit_installations DROP CONSTRAINT repository_kit_installations_state_shape"
    )

    create constraint(
             :repository_kit_installations,
             :repository_kit_installations_state_shape,
             check: "state IN ('applied', 'updated', 'removed')"
           )
  end

  def down do
    execute(
      "ALTER TABLE repository_kit_installations DROP CONSTRAINT repository_kit_installations_state_shape"
    )

    create constraint(
             :repository_kit_installations,
             :repository_kit_installations_state_shape,
             check: "state IN ('applied', 'updated')"
           )
  end
end
