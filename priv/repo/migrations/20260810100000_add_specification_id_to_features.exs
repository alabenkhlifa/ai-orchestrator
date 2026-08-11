defmodule SddOrchestrator.Repo.Migrations.AddSpecificationIdToFeatures do
  use Ecto.Migration

  def change do
    alter table(:features) do
      add :specification_id, :string
    end

    create unique_index(:features, [:project_id, :specification_id],
             name: :features_project_id_specification_id_index,
             where: "specification_id IS NOT NULL"
           )
  end
end
