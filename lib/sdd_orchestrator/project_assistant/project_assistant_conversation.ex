defmodule SddOrchestrator.ProjectAssistant.ProjectAssistantConversation do
  @moduledoc """
  One private hosted conversation for one stable participant identity and
  one project.

  Privacy is enforced by identity, not by capability: any current project
  member — owner or participant — may hold at most one conversation here
  (`unique_index` on `project_id` and `account_id`), reachable only through
  their own re-verified current participation. It is never projected into
  shared project activity, a comment, or a feature record.

  Later tasks extend this shape with the disclosure/confirmation reference,
  processing-boundary fields, and lifecycle-state columns their own
  migrations add; this schema only carries the identity, ordering, and
  last-activity boundary Task 1 owns.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias SddOrchestrator.Accounts.Account
  alias SddOrchestrator.ProjectAssistant.ProjectAssistantTurn
  alias SddOrchestrator.Projects.Project

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  @type t :: %__MODULE__{}

  schema "project_assistant_conversations" do
    field :last_activity_at, :utc_datetime

    belongs_to :project, Project
    belongs_to :account, Account

    has_many :turns, ProjectAssistantTurn, foreign_key: :conversation_id

    timestamps()
  end

  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(conversation, attrs) do
    conversation
    |> cast(attrs, [:project_id, :account_id, :last_activity_at])
    |> validate_required([:project_id, :account_id, :last_activity_at])
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:account_id)
    |> unique_constraint([:project_id, :account_id],
      name: :project_assistant_conversations_project_id_account_id_index
    )
  end

  @doc "Records the acting participant's own conversation getting new activity."
  @spec touch_changeset(t(), DateTime.t()) :: Ecto.Changeset.t()
  def touch_changeset(conversation, last_activity_at) do
    change(conversation, last_activity_at: last_activity_at)
  end
end
