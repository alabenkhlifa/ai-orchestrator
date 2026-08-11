defmodule SddOrchestrator.Repo.Migrations.CreateRepositoryKitChangePlans do
  use Ecto.Migration

  def up do
    create table(:repository_kit_change_plans, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :package_id,
          references(:repository_kit_packages, type: :binary_id, on_delete: :restrict),
          null: false

      add :package_digest, :string, null: false

      add :profile_version, :integer, null: false
      add :base_commit, :string, null: false
      add :root, :text, null: false
      add :repository_provider, :string, null: false
      add :repository_id, :string, null: false

      add :target_branch, :string, null: false

      add :operations, {:array, :map}, null: false, default: []
      add :safety_blocked, :boolean, null: false, default: false
      add :has_ordinary_conflicts, :boolean, null: false, default: false

      add :expires_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:repository_kit_change_plans, [:project_id, :inserted_at])
    create index(:repository_kit_change_plans, [:package_id])

    create constraint(
             :repository_kit_change_plans,
             :repository_kit_change_plans_profile_version_positive,
             check: "profile_version > 0"
           )

    create constraint(:repository_kit_change_plans, :repository_kit_change_plans_commit_shape,
             check: "base_commit ~ '^([0-9a-f]{40}|[0-9a-f]{64})$'"
           )

    create constraint(:repository_kit_change_plans, :repository_kit_change_plans_digest_shape,
             check: "package_digest ~ '^[0-9a-f]{64}$'"
           )

    execute("""
    CREATE FUNCTION reject_repository_kit_change_plan_update()
    RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'repository kit change plans are immutable';
    END;
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE TRIGGER repository_kit_change_plans_immutable
    BEFORE UPDATE ON repository_kit_change_plans
    FOR EACH ROW EXECUTE FUNCTION reject_repository_kit_change_plan_update()
    """)
  end

  def down do
    execute(
      "DROP TRIGGER IF EXISTS repository_kit_change_plans_immutable ON repository_kit_change_plans"
    )

    execute("DROP FUNCTION IF EXISTS reject_repository_kit_change_plan_update()")
    drop table(:repository_kit_change_plans)
  end
end
