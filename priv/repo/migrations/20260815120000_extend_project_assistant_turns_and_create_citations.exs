defmodule SddOrchestrator.Repo.Migrations.ExtendProjectAssistantTurnsAndCreateCitations do
  use Ecto.Migration

  def change do
    alter table(:project_assistant_turns) do
      # The composed answer text, encrypted at rest through
      # `SddOrchestrator.Vault` exactly like `question_text` — never
      # plaintext in a backup, log line, or crash report. Null until a
      # turn's answer-composition step actually runs; a bare question-only
      # row (Task 1's own proof inserts) never sets it.
      add :answer_text, :binary

      # The exact `ProjectContextProjection.context_version` this turn's
      # stored-context grounding read, so a citation or a later re-open can
      # prove which assembled snapshot supported the answer. Null when the
      # turn never reached context assembly.
      add :context_version, :string

      # Visible, explicit uncertainty beside the affected conclusion
      # (AC-12): partial | stale | excluded | unavailable | conflicting |
      # unstable, each with a human-readable detail. Defaults to an empty
      # array rather than a set of markers, mirroring
      # `run_attempts.required_checks`'s own array-as-jsonb default.
      add :uncertainty_markers, :jsonb, null: false, default: fragment("'[]'::jsonb")

      # The normalized turn outcome. Null for a bare question-only row that
      # never reached answer composition; every row Task 7's orchestrator
      # persists sets exactly one of the three.
      add :outcome, :string

      # A normalized, closed failure reason — never a raw provider error,
      # exception message, or stack trace — set only when outcome is
      # "failed".
      add :failure_reason, :string
    end

    create constraint(:project_assistant_turns, :project_assistant_turns_outcome_check,
             check: "outcome IS NULL OR outcome IN ('answered', 'cancelled', 'failed')"
           )

    create constraint(
             :project_assistant_turns,
             :project_assistant_turns_uncertainty_markers_array,
             check: "jsonb_typeof(uncertainty_markers) = 'array'"
           )

    create table(:project_assistant_citations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :turn_id,
          references(:project_assistant_turns, type: :binary_id, on_delete: :delete_all),
          null: false

      # Denormalized like `project_assistant_turns.project_id`, so every
      # citation query and constraint stays scoped to one project without a
      # join through the turn.
      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :source_type, :string, null: false

      # The exact typed identity for `source_type`: specification id and
      # revision id; board feature id; run id and attempt number; evidence
      # id; or repository path, start/end line, branch, commit, dirty and
      # stability state. See `ProjectAssistantCitation` for the closed shape
      # per type. Never a raw repository search result or a full document
      # body.
      add :reference, :map, null: false

      # The minimal cited excerpt only (the "minimal excerpt policy" owned
      # surface), encrypted at rest exactly like `question_text` — the same
      # treatment any repository-derived content gets. Null for a source
      # type with no meaningful excerpt of its own (e.g. a board item).
      add :excerpt, :binary

      # No `updated_at`: a citation is appended once, atomically with its
      # turn, and never rewritten.
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:project_assistant_citations, [:turn_id])
    create index(:project_assistant_citations, [:project_id])

    create constraint(
             :project_assistant_citations,
             :project_assistant_citations_source_type_check,
             check: "source_type IN ('specification', 'repository', 'board', 'run', 'evidence')"
           )
  end
end
