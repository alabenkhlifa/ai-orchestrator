defmodule SddOrchestrator.ProjectAssistant.ProjectAssistantTurn do
  @moduledoc """
  One private, ordered question appended to a hosted
  `ProjectAssistantConversation`.

  A turn is append-only: creation fixes its `sequence` inside its
  conversation (`unique_index` on `conversation_id` and `sequence`) and
  nothing here updates it afterward. The question text is encrypted at rest
  through `SddOrchestrator.Vault`, the same treatment evidence content gets.

  Later tasks add the answer, citations, context-version references, runtime
  state, uncertainty markers, and cancellation or failure outcome through
  their own migrations and changesets; this shape only proves identity and
  order.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias SddOrchestrator.ProjectAssistant.ProjectAssistantConversation
  alias SddOrchestrator.Projects.Project

  @max_question_bytes 4_000

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime, updated_at: false]

  @type t :: %__MODULE__{}

  schema "project_assistant_turns" do
    field :sequence, :integer
    field :question_text, SddOrchestrator.Encrypted.Binary, redact: true

    belongs_to :conversation, ProjectAssistantConversation
    belongs_to :project, Project

    timestamps()
  end

  @spec max_question_bytes() :: pos_integer()
  def max_question_bytes, do: @max_question_bytes

  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(turn, attrs) do
    turn
    |> cast(attrs, [:conversation_id, :project_id, :sequence, :question_text])
    |> trim_question_text()
    |> validate_required([:conversation_id, :project_id, :sequence, :question_text])
    |> validate_number(:sequence, greater_than: 0)
    |> validate_length(:question_text, max: @max_question_bytes, count: :bytes)
    |> validate_change(:question_text, fn :question_text, text ->
      if Regex.match?(~r/\p{Cc}/u, text),
        do: [question_text: "must not contain control characters"],
        else: []
    end)
    |> foreign_key_constraint(:conversation_id)
    |> foreign_key_constraint(:project_id)
    |> unique_constraint([:conversation_id, :sequence],
      name: :project_assistant_turns_conversation_id_sequence_index
    )
    |> check_constraint(:sequence, name: :project_assistant_turns_sequence_positive)
  end

  defp trim_question_text(changeset) do
    case fetch_change(changeset, :question_text) do
      {:ok, text} when is_binary(text) -> put_change(changeset, :question_text, String.trim(text))
      _other -> changeset
    end
  end
end
