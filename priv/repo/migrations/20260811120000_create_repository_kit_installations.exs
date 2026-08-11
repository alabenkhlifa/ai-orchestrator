defmodule SddOrchestrator.Repo.Migrations.CreateRepositoryKitInstallations do
  use Ecto.Migration

  def up do
    create table(:repository_kit_installations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :package_id,
          references(:repository_kit_packages, type: :binary_id, on_delete: :restrict),
          null: false

      add :plan_id,
          references(:repository_kit_change_plans, type: :binary_id, on_delete: :restrict),
          null: false

      add :package_digest, :string, null: false

      add :profile_version, :integer, null: false
      add :base_commit, :string, null: false
      add :root, :text, null: false
      add :repository_provider, :string, null: false
      add :repository_id, :string, null: false

      add :branch, :string, null: false
      add :result_commit, :string, null: false

      add :installed_files, {:array, :map}, null: false, default: []

      add :state, :string, null: false, default: "applied"
      add :evidence, :map, null: false, default: %{}

      add :confirmed_by_actor_ref, :binary_id, null: false
      add :confirmed_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:repository_kit_installations, [:plan_id])
    create index(:repository_kit_installations, [:project_id, :inserted_at])

    create constraint(
             :repository_kit_installations,
             :repository_kit_installations_profile_version_positive,
             check: "profile_version > 0"
           )

    create constraint(
             :repository_kit_installations,
             :repository_kit_installations_base_commit_shape,
             check: "base_commit ~ '^([0-9a-f]{40}|[0-9a-f]{64})$'"
           )

    create constraint(
             :repository_kit_installations,
             :repository_kit_installations_result_commit_shape,
             check: "result_commit ~ '^([0-9a-f]{40}|[0-9a-f]{64})$'"
           )

    create constraint(:repository_kit_installations, :repository_kit_installations_digest_shape,
             check: "package_digest ~ '^[0-9a-f]{64}$'"
           )

    create constraint(:repository_kit_installations, :repository_kit_installations_state_shape,
             check: "state IN ('applied')"
           )
  end

  def down do
    drop table(:repository_kit_installations)
  end
end
