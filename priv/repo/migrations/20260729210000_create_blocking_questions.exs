defmodule SddOrchestrator.Repo.Migrations.CreateBlockingQuestions do
  use Ecto.Migration

  def change do
    create table(:blocking_questions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :feature_id, references(:features, type: :binary_id, on_delete: :delete_all),
        null: false

      add :run_id, references(:agent_runs, type: :binary_id, on_delete: :delete_all), null: false

      # The asking attempt is history: a later attempt of the same run answers
      # the question, so the reference is cleared rather than cascading when the
      # attempt itself is cleaned up.
      add :attempt_id, references(:run_attempts, type: :binary_id, on_delete: :nilify_all)

      # One focused decision and the reasoning a responder needs to make it.
      # Both are bounded so an agent cannot turn a question into a transcript.
      add :question, :text, null: false
      add :context, :text

      add :state, :string, null: false, default: "open"

      # What a later attempt resumes from. Preserving the branch, the workspace,
      # and the checkpoint together is what makes an answer continue accepted
      # work instead of repeating it.
      add :checkpoint, :map, null: false, default: %{}
      add :branch, :string, null: false
      add :workspace_path, :string, null: false

      add :asked_at, :utc_datetime_usec, null: false
      add :state_version, :integer, null: false, default: 1

      timestamps(type: :utc_datetime)
    end

    create index(:blocking_questions, [:project_id])
    create index(:blocking_questions, [:feature_id, :state])
    create index(:blocking_questions, [:attempt_id])

    # At most one open question per run. This is the database-level form of
    # "one run asks one focused question": a redelivered blocked event, a
    # reconnecting worker, or an agent that keeps talking cannot leave a reader
    # with two competing decisions to make.
    create unique_index(:blocking_questions, [:run_id],
             where: "state = 'open'",
             name: :blocking_questions_one_open_question
           )

    create constraint(:blocking_questions, :blocking_questions_state_allowed,
             check: "state IN ('open', 'answered', 'superseded')"
           )

    create constraint(:blocking_questions, :blocking_questions_question_length,
             check: "octet_length(question) > 0 AND octet_length(question) <= 2000"
           )

    create constraint(:blocking_questions, :blocking_questions_context_length,
             check: "context IS NULL OR octet_length(context) <= 4000"
           )

    create constraint(:blocking_questions, :blocking_questions_branch_length,
             check: "octet_length(branch) > 0 AND octet_length(branch) <= 200"
           )

    create constraint(:blocking_questions, :blocking_questions_workspace_path_length,
             check: "octet_length(workspace_path) > 0 AND octet_length(workspace_path) <= 1000"
           )

    create constraint(:blocking_questions, :blocking_questions_state_version_positive,
             check: "state_version > 0"
           )
  end
end
