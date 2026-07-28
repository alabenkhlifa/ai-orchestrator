defmodule SddOrchestrator.Repo.Migrations.CreateProjectSpecificationStore do
  use Ecto.Migration

  def change do
    create table(:project_specifications, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :title, :string, null: false
      add :current_revision_id, :binary_id

      timestamps(type: :utc_datetime)
    end

    create index(:project_specifications, [:project_id])

    create table(:specification_revisions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :specification_id,
          references(:project_specifications, type: :binary_id, on_delete: :delete_all),
          null: false

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :sequence, :integer, null: false
      add :requirements_document, :text, null: false
      add :design_document, :text, null: false
      add :tasks_document, :text, null: false
      add :content_digest, :string, null: false
      add :actor_ref, :string

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:specification_revisions, [:specification_id, :sequence])
    create index(:specification_revisions, [:project_id])

    create constraint(:specification_revisions, :specification_revisions_sequence_positive,
             check: "sequence > 0"
           )

    alter table(:project_specifications) do
      modify :current_revision_id,
             references(:specification_revisions, type: :binary_id, on_delete: :nothing),
             from: :binary_id
    end

    create index(:project_specifications, [:current_revision_id])
  end
end
