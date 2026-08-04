defmodule SddOrchestrator.Repo.Migrations.CreateRepositoryAssessmentProposalEnvelopes do
  use Ecto.Migration

  def up do
    create table(:repository_assessment_proposal_envelopes, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :assessment_id,
          references(:repository_assessments, type: :binary_id, on_delete: :delete_all),
          null: false

      add :version, :integer, null: false
      add :cache_key_sha256, :string, null: false
      add :evidence_sha256, :string, null: false
      add :result_sha256, :string, null: false
      add :payload_digest, :string, null: false
      add :envelope_digest, :string, null: false
      add :commands, {:array, :text}, null: false, default: []
      add :required_checks, {:array, :text}, null: false, default: []
      add :allowed_scope, {:array, :text}, null: false
      add :gaps, {:array, :string}, null: false, default: []
      add :conflicts, {:array, :string}, null: false, default: []
      add :multi_root_blockers, {:array, :text}, null: false, default: []

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:repository_assessment_proposal_envelopes, [:assessment_id],
             name: :repository_assessment_proposal_envelopes_assessment_index
           )

    create index(:repository_assessment_proposal_envelopes, [:project_id])

    create constraint(
             :repository_assessment_proposal_envelopes,
             :repository_assessment_proposal_envelopes_version_positive,
             check: "version > 0"
           )

    create constraint(
             :repository_assessment_proposal_envelopes,
             :repository_assessment_proposal_envelopes_digest_shape,
             check: """
             cache_key_sha256 ~ '^[0-9a-f]{64}$'
             AND evidence_sha256 ~ '^[0-9a-f]{64}$'
             AND result_sha256 ~ '^[0-9a-f]{64}$'
             AND payload_digest ~ '^[0-9a-f]{64}$'
             AND envelope_digest ~ '^[0-9a-f]{64}$'
             """
           )

    execute("""
    CREATE FUNCTION reject_repository_assessment_proposal_envelope_update()
    RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'repository assessment proposal envelopes are immutable';
    END;
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE TRIGGER repository_assessment_proposal_envelopes_immutable
    BEFORE UPDATE ON repository_assessment_proposal_envelopes
    FOR EACH ROW EXECUTE FUNCTION reject_repository_assessment_proposal_envelope_update()
    """)
  end

  def down do
    execute("""
    DROP TRIGGER IF EXISTS repository_assessment_proposal_envelopes_immutable
    ON repository_assessment_proposal_envelopes
    """)

    execute("DROP FUNCTION IF EXISTS reject_repository_assessment_proposal_envelope_update()")
    drop table(:repository_assessment_proposal_envelopes)
  end
end
