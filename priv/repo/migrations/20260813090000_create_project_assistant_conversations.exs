defmodule SddOrchestrator.Repo.Migrations.CreateProjectAssistantConversations do
  use Ecto.Migration

  def change do
    create table(:project_assistant_conversations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      # The stable participant identity a conversation is private to. An
      # account rather than a hosted identity: the project owner has no
      # hosted identity at all, and a departed-then-reinvited participant's
      # hosted identity can change while their account stays the same
      # private conversation owner.
      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :last_activity_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    # One private conversation per participant per project — the identity
    # boundary AC-02 and AC-03 depend on.
    create unique_index(:project_assistant_conversations, [:project_id, :account_id])

    create table(:project_assistant_turns, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :conversation_id,
          references(:project_assistant_conversations, type: :binary_id, on_delete: :delete_all),
          null: false

      # Denormalized like `specification_revisions.project_id`, so every turn
      # query and constraint stays scoped to one project without a join.
      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :sequence, :integer, null: false

      # The participant's private question text. Encrypted at rest through
      # `SddOrchestrator.Vault`, the same treatment evidence content gets:
      # this never appears in a backup, log line, or crash report as
      # plaintext. Later tasks add the answer, citations, context-version
      # references, runtime state, and uncertainty markers through their own
      # migrations — this shape only proves identity and order.
      add :question_text, :binary, null: false

      # No `updated_at`: a turn is appended, never rewritten.
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:project_assistant_turns, [:project_id])

    # Strict per-conversation ordering: the ordered turn lifecycle Task 1 owns.
    create unique_index(:project_assistant_turns, [:conversation_id, :sequence])

    create constraint(:project_assistant_turns, :project_assistant_turns_sequence_positive,
             check: "sequence > 0"
           )
  end
end
