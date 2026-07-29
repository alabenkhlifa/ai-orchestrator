defmodule SddOrchestrator.Repo.Migrations.CreateEvidenceArtifacts do
  use Ecto.Migration

  def change do
    create table(:evidence_artifacts, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      # The digest addresses the content within its project. Provenance — which
      # run, attempt, branch, and commit produced it — lives on the evidence row
      # that names the reference and is deliberately not duplicated here.
      add :digest, :string, null: false
      add :content_type, :string, null: false
      add :byte_size, :integer, null: false
      add :redacted, :boolean, null: false, default: false

      # Private project data, encrypted at rest through `SddOrchestrator.Vault`.
      # There is deliberately no URL, path, host, or expiry column: an artifact
      # is reachable only through an authorized fetch against this table.
      add :content, :binary, null: false

      # No `updated_at`: an artifact is addressed by the digest of its own
      # content, so a stored row is never rewritten.
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:evidence_artifacts, [:project_id])

    # Content-addressed within one project: the same bytes stored twice are one
    # artifact, and one project's artifact is never another project's.
    create unique_index(:evidence_artifacts, [:project_id, :digest])

    create constraint(:evidence_artifacts, :evidence_artifacts_digest_format,
             check: "digest ~ '^[0-9a-f]{64}$'"
           )

    create constraint(:evidence_artifacts, :evidence_artifacts_content_type_allowed,
             check: "content_type IN ('image/png', 'image/jpeg', 'image/webp', 'text/plain')"
           )

    # The recorded size has to be the size of what is stored, and neither may be
    # empty or larger than the 5 MiB both adapters accept.
    create constraint(:evidence_artifacts, :evidence_artifacts_byte_size_bounded,
             check: "byte_size > 0 AND byte_size <= 5242880"
           )
  end
end
