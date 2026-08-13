defmodule SddOrchestrator.Repo.Migrations.AddLifecycleFieldsToRepositoryKitInstallations do
  use Ecto.Migration

  def up do
    execute(
      "ALTER TABLE repository_kit_installations DROP CONSTRAINT repository_kit_installations_state_shape"
    )

    create constraint(
             :repository_kit_installations,
             :repository_kit_installations_state_shape,
             check: "state IN ('applied', 'updated')"
           )

    alter table(:repository_kit_installations) do
      add :history, {:array, :map}, null: false, default: []
    end

    create unique_index(:repository_kit_installations, [:project_id],
             name: :repository_kit_installations_project_id_index
           )
  end

  def down do
    drop unique_index(:repository_kit_installations, [:project_id],
           name: :repository_kit_installations_project_id_index
         )

    alter table(:repository_kit_installations) do
      remove :history
    end

    execute(
      "ALTER TABLE repository_kit_installations DROP CONSTRAINT repository_kit_installations_state_shape"
    )

    create constraint(
             :repository_kit_installations,
             :repository_kit_installations_state_shape,
             check: "state IN ('applied')"
           )
  end
end
