defmodule SddOrchestrator.Repo.Migrations.CreateRepositoryExecutionProfiles do
  use Ecto.Migration

  def up do
    create table(:repository_execution_profiles, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :assessment_id,
          references(:repository_assessments, type: :binary_id, on_delete: :delete_all),
          null: false

      add :version, :integer, null: false
      add :repository_provider, :string, null: false
      add :repository_id, :string, null: false
      add :root, :text, null: false
      add :base_revision, :string, null: false
      add :assessment_digest, :string, null: false
      add :proposal_digest, :string, null: false
      add :instruction_precedence, {:array, :map}, null: false, default: []
      add :commands, {:array, :text}, null: false, default: []
      add :required_checks, {:array, :text}, null: false, default: []
      add :allowed_scope, {:array, :text}, null: false
      add :gaps, {:array, :string}, null: false, default: []
      add :conflicts, {:array, :string}, null: false, default: []
      add :multi_root_blockers, {:array, :text}, null: false, default: []
      add :approval_actor_ref, :binary_id, null: false
      add :approved_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:repository_execution_profiles, [:project_id, :version],
             name: :repository_execution_profiles_project_version_index
           )

    create unique_index(
             :repository_execution_profiles,
             [:project_id, :assessment_id, :proposal_digest],
             name: :repository_execution_profiles_project_assessment_proposal_index
           )

    create index(:repository_execution_profiles, [:assessment_id])

    create constraint(
             :repository_execution_profiles,
             :repository_execution_profiles_version_positive,
             check: "version > 0"
           )

    create constraint(:repository_execution_profiles, :repository_execution_profiles_commit_shape,
             check: "base_revision ~ '^([0-9a-f]{40}|[0-9a-f]{64})$'"
           )

    create constraint(:repository_execution_profiles, :repository_execution_profiles_digest_shape,
             check: "assessment_digest ~ '^[0-9a-f]{64}$' AND proposal_digest ~ '^[0-9a-f]{64}$'"
           )

    execute("""
    CREATE FUNCTION reject_repository_execution_profile_update()
    RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'repository execution profile versions are immutable';
    END;
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE TRIGGER repository_execution_profiles_immutable
    BEFORE UPDATE ON repository_execution_profiles
    FOR EACH ROW EXECUTE FUNCTION reject_repository_execution_profile_update()
    """)
  end

  def down do
    execute(
      "DROP TRIGGER IF EXISTS repository_execution_profiles_immutable ON repository_execution_profiles"
    )

    execute("DROP FUNCTION IF EXISTS reject_repository_execution_profile_update()")
    drop table(:repository_execution_profiles)
  end
end
