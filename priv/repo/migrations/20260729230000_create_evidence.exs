defmodule SddOrchestrator.Repo.Migrations.CreateEvidence do
  use Ecto.Migration

  def change do
    create table(:evidence, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :feature_id, references(:features, type: :binary_id, on_delete: :delete_all),
        null: false

      add :run_id, references(:agent_runs, type: :binary_id, on_delete: :delete_all), null: false

      # The producing attempt is history: a later attempt of the same run records
      # its own evidence, so the link is cleared rather than cascading when the
      # attempt is cleaned up. The proof itself outlives the attempt.
      add :attempt_id, references(:run_attempts, type: :binary_id, on_delete: :nilify_all)

      # The worker command this result came out of, as the protocol names it.
      # Provenance rather than a foreign key: retention removes the transient
      # dispatch record long before the evidence it produced.
      add :command_id, :string, null: false

      add :kind, :string, null: false
      add :name, :string, null: false
      add :outcome, :string, null: false

      # What lets someone who was not there check the outcome for themselves:
      # the exact command, how it exited, how long it took, and the precise
      # branch and commit it ran against. Without these an outcome is a claim.
      add :command, :text
      add :exit_code, :integer
      add :duration_ms, :integer, null: false
      add :branch, :string, null: false
      add :commit_sha, :string, null: false

      # `agent` is deliberately absent from the allowed sources below. Proof is
      # a command result; what the agent said about its own work is narrative.
      add :source, :string, null: false
      add :recorded_at, :utc_datetime_usec, null: false

      add :digest, :string, null: false
      add :redacted, :boolean, null: false, default: false

      # Bytes live in the private artifact store; this row holds only the
      # reference to them, never a public URL or an embedded credential.
      add :artifact_ref, :string

      # A rerun never rewrites what it disagrees with. It records a new row and
      # points the old one at it, so a reader still sees that the earlier result
      # existed and what replaced it.
      add :superseded_by_id, references(:evidence, type: :binary_id, on_delete: :nilify_all)

      add :state_version, :integer, null: false, default: 1

      # There is no `updated_at`: the only write an existing row ever receives is
      # the supersession link, and that is not a modification of the proof.
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:evidence, [:project_id])
    create index(:evidence, [:feature_id])
    create index(:evidence, [:attempt_id])
    create index(:evidence, [:superseded_by_id])

    # Completion is judged per run against one exact commit, so that is the
    # question the index has to answer cheaply.
    create index(:evidence, [:run_id, :commit_sha])

    create constraint(:evidence, :evidence_kind_allowed,
             check: "kind IN ('required_check', 'screenshot', 'preview')"
           )

    create constraint(:evidence, :evidence_outcome_allowed,
             check: "outcome IN ('passed', 'failed', 'missing', 'unsupported')"
           )

    # The database-level form of "an agent narrative is never proof". No code
    # path, migration, or console session can record agent-sourced evidence.
    create constraint(:evidence, :evidence_source_allowed, check: "source IN ('check', 'worker')")

    # A required check reports the command it ran and how that command exited,
    # including when it could not produce a usable result. An outcome without
    # exit provenance is exactly the unsupported completion claim this table
    # exists to replace.
    create constraint(:evidence, :evidence_required_check_provenance,
             check: """
             kind <> 'required_check'
               OR (command IS NOT NULL AND octet_length(command) > 0 AND exit_code IS NOT NULL)
             """
           )

    create constraint(:evidence, :evidence_duration_non_negative, check: "duration_ms >= 0")

    create constraint(:evidence, :evidence_name_length,
             check: "octet_length(name) > 0 AND octet_length(name) <= 200"
           )

    create constraint(:evidence, :evidence_command_length,
             check: "command IS NULL OR octet_length(command) <= 2000"
           )

    create constraint(:evidence, :evidence_branch_length,
             check: "octet_length(branch) > 0 AND octet_length(branch) <= 200"
           )

    create constraint(:evidence, :evidence_commit_sha_length,
             check: "octet_length(commit_sha) > 0 AND octet_length(commit_sha) <= 64"
           )

    create constraint(:evidence, :evidence_artifact_ref_length,
             check: "artifact_ref IS NULL OR octet_length(artifact_ref) <= 512"
           )

    # Content-addressed or not stored at all: a digest is what makes the item
    # verifiable against the artifact a later reader retrieves.
    create constraint(:evidence, :evidence_digest_format, check: "digest ~ '^[0-9a-f]{64}$'")

    create constraint(:evidence, :evidence_supersession_distinct,
             check: "superseded_by_id IS NULL OR superseded_by_id <> id"
           )

    create constraint(:evidence, :evidence_state_version_positive, check: "state_version > 0")

    # Evidence is immutable at the database, not merely by convention. The one
    # write a stored row may still receive is the link to whatever superseded
    # it, together with the optimistic-lock version that write carries; every
    # other column is frozen. Deletion stays available so project deletion and
    # retention still work.
    execute """
            CREATE OR REPLACE FUNCTION evidence_reject_rewrite()
            RETURNS trigger AS $$
            BEGIN
              IF OLD.superseded_by_id IS NOT NULL THEN
                RAISE EXCEPTION 'evidence supersession is recorded once';
              END IF;

              IF NEW.id IS DISTINCT FROM OLD.id
                OR NEW.project_id IS DISTINCT FROM OLD.project_id
                OR NEW.feature_id IS DISTINCT FROM OLD.feature_id
                OR NEW.run_id IS DISTINCT FROM OLD.run_id
                OR NEW.attempt_id IS DISTINCT FROM OLD.attempt_id
                OR NEW.command_id IS DISTINCT FROM OLD.command_id
                OR NEW.kind IS DISTINCT FROM OLD.kind
                OR NEW.name IS DISTINCT FROM OLD.name
                OR NEW.outcome IS DISTINCT FROM OLD.outcome
                OR NEW.command IS DISTINCT FROM OLD.command
                OR NEW.exit_code IS DISTINCT FROM OLD.exit_code
                OR NEW.duration_ms IS DISTINCT FROM OLD.duration_ms
                OR NEW.branch IS DISTINCT FROM OLD.branch
                OR NEW.commit_sha IS DISTINCT FROM OLD.commit_sha
                OR NEW.source IS DISTINCT FROM OLD.source
                OR NEW.recorded_at IS DISTINCT FROM OLD.recorded_at
                OR NEW.digest IS DISTINCT FROM OLD.digest
                OR NEW.redacted IS DISTINCT FROM OLD.redacted
                OR NEW.artifact_ref IS DISTINCT FROM OLD.artifact_ref
                OR NEW.inserted_at IS DISTINCT FROM OLD.inserted_at
              THEN
                RAISE EXCEPTION 'evidence is immutable except for its supersession link';
              END IF;

              RETURN NEW;
            END;
            $$ LANGUAGE plpgsql;
            """,
            "DROP FUNCTION IF EXISTS evidence_reject_rewrite();"

    execute """
            CREATE TRIGGER evidence_no_rewrite
            BEFORE UPDATE ON evidence
            FOR EACH ROW EXECUTE FUNCTION evidence_reject_rewrite();
            """,
            "DROP TRIGGER IF EXISTS evidence_no_rewrite ON evidence;"
  end
end
