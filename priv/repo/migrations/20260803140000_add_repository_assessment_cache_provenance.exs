defmodule SddOrchestrator.Repo.Migrations.AddRepositoryAssessmentCacheProvenance do
  use Ecto.Migration

  def up do
    alter table(:repository_assessments) do
      add :cache_source, :string
      add :cache_key_sha256, :string
      add :evidence_sha256, :string
      add :cache_stored, :boolean
    end

    create constraint(
             :repository_assessments,
             :repository_assessments_cache_provenance_all_or_none,
             check: """
             (cache_source IS NULL AND cache_key_sha256 IS NULL
               AND evidence_sha256 IS NULL AND cache_stored IS NULL)
             OR
             (cache_source IS NOT NULL AND cache_key_sha256 IS NOT NULL
               AND evidence_sha256 IS NOT NULL AND cache_stored IS NOT NULL)
             """
           )

    create constraint(
             :repository_assessments,
             :repository_assessments_cache_source,
             check: "cache_source IS NULL OR cache_source IN ('fresh_scan', 'complete_cache')"
           )

    create constraint(
             :repository_assessments,
             :repository_assessments_cache_digest_shape,
             check: """
             (cache_key_sha256 IS NULL OR cache_key_sha256 ~ '^[0-9a-f]{64}$')
             AND (evidence_sha256 IS NULL OR evidence_sha256 ~ '^[0-9a-f]{64}$')
             """
           )

    create constraint(
             :repository_assessments,
             :repository_assessments_complete_cache_stored,
             check: "cache_source IS DISTINCT FROM 'complete_cache' OR cache_stored = TRUE"
           )

    create constraint(
             :repository_assessments,
             :repository_assessments_cache_provenance_completed_only,
             check: """
             state = 'completed'
             OR
             (cache_source IS NULL AND cache_key_sha256 IS NULL
               AND evidence_sha256 IS NULL AND cache_stored IS NULL)
             """
           )
  end

  def down do
    drop constraint(
           :repository_assessments,
           :repository_assessments_cache_provenance_completed_only
         )

    drop constraint(:repository_assessments, :repository_assessments_complete_cache_stored)
    drop constraint(:repository_assessments, :repository_assessments_cache_digest_shape)
    drop constraint(:repository_assessments, :repository_assessments_cache_source)

    drop constraint(
           :repository_assessments,
           :repository_assessments_cache_provenance_all_or_none
         )

    alter table(:repository_assessments) do
      remove :cache_stored
      remove :evidence_sha256
      remove :cache_key_sha256
      remove :cache_source
    end
  end
end
