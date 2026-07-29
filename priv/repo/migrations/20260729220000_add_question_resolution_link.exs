defmodule SddOrchestrator.Repo.Migrations.AddQuestionResolutionLink do
  use Ecto.Migration

  def change do
    # An answered question names the revision its answer produced. Without the
    # link the durable agreement and the question that changed it are two
    # records nobody can join, and a later reader cannot tell which answer moved
    # the specification.
    alter table(:blocking_questions) do
      add :resulting_revision_id, :string
    end

    create constraint(:blocking_questions, :blocking_questions_resolution_link,
             check: "state <> 'answered' OR resulting_revision_id IS NOT NULL"
           )
  end
end
