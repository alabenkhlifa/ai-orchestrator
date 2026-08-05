defmodule SddOrchestrator.Repo.Migrations.CreateRepositoryPilotSelections do
  use Ecto.Migration

  def change do
    create table(:repository_pilot_selections, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      # The bound approved profile is owned by this database, so it is a real
      # reference: a pilot may never outlive the execution profile it adopted.
      add :profile_id,
          references(:repository_execution_profiles, type: :binary_id, on_delete: :delete_all),
          null: false

      add :profile_version, :integer, null: false

      # The piloted specification belongs to the shared store, so it is
      # referenced by identity and digest only. A device-authoritative revision
      # has no hosted row, so a foreign key is impossible here. There is
      # deliberately no title and no document column: a pilot points at the one
      # authoritative specification, it never becomes a second copy of it.
      add :specification_id, :string, null: false
      add :revision_id, :string, null: false
      add :revision_digest, :string, null: false

      add :selected_by_actor_ref, :binary_id, null: false
      add :selected_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    # One pilot per project: re-selecting replaces the single current pilot
    # rather than accumulating a history of contradictory adoptions.
    create unique_index(:repository_pilot_selections, [:project_id])
    create index(:repository_pilot_selections, [:profile_id])

    create constraint(
             :repository_pilot_selections,
             :repository_pilot_selections_profile_version_positive,
             check: "profile_version > 0"
           )
  end
end
