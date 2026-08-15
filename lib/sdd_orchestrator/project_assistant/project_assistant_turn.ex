defmodule SddOrchestrator.ProjectAssistant.ProjectAssistantTurn do
  @moduledoc """
  One private, ordered question appended to a hosted
  `ProjectAssistantConversation`.

  A turn is append-only: creation fixes its `sequence` inside its
  conversation (`unique_index` on `conversation_id` and `sequence`) and
  nothing here updates it afterward. The question text is encrypted at rest
  through `SddOrchestrator.Vault`, the same treatment evidence content gets.

  Task 7 extends this shape with the answer, the stored-context version it
  grounded on, visible uncertainty markers, and a normalized cancellation or
  failure outcome (AC-10, AC-11, AC-12) — all set exactly once, atomically
  with creation, by `SddOrchestrator.ProjectAssistant.TurnAnswerStore`.
  `answer_text` is encrypted at rest exactly like `question_text`.
  `uncertainty_markers` is a closed, typed list (see
  `SddOrchestrator.ProjectAssistant.UncertaintyMarker`) stored as plain
  string-keyed maps. Every new field is optional at the changeset level so
  Task 1's own bare question-only insert (`ProjectAssistantStore.append_turn/4`)
  remains valid unchanged: those rows simply carry `outcome: nil` and an
  empty `uncertainty_markers` list, never a fabricated answer.

  This entity's citations (`entity:ProjectAssistantCitation`) live in their
  own table (`has_many :citations`), keyed to this turn — see
  `SddOrchestrator.ProjectAssistant.ProjectAssistantCitation`.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias SddOrchestrator.ProjectAssistant.{ProjectAssistantCitation, ProjectAssistantConversation}
  alias SddOrchestrator.Projects.Project

  @max_question_bytes 4_000
  @outcomes ~w(answered cancelled failed)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime, updated_at: false]

  @type t :: %__MODULE__{}

  schema "project_assistant_turns" do
    field :sequence, :integer
    field :question_text, SddOrchestrator.Encrypted.Binary, redact: true
    field :answer_text, SddOrchestrator.Encrypted.Binary, redact: true
    field :context_version, :string
    field :uncertainty_markers, {:array, :map}, default: []
    field :outcome, :string
    field :failure_reason, :string

    belongs_to :conversation, ProjectAssistantConversation
    belongs_to :project, Project

    has_many :citations, ProjectAssistantCitation, foreign_key: :turn_id

    timestamps()
  end

  @spec max_question_bytes() :: pos_integer()
  def max_question_bytes, do: @max_question_bytes

  @spec outcomes() :: [String.t()]
  def outcomes, do: @outcomes

  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(turn, attrs) do
    turn
    |> cast(attrs, [
      :conversation_id,
      :project_id,
      :sequence,
      :question_text,
      :answer_text,
      :context_version,
      :uncertainty_markers,
      :outcome,
      :failure_reason
    ])
    |> trim_question_text()
    |> validate_required([:conversation_id, :project_id, :sequence, :question_text])
    |> validate_number(:sequence, greater_than: 0)
    |> validate_length(:question_text, max: @max_question_bytes, count: :bytes)
    |> validate_change(:question_text, fn :question_text, text ->
      if Regex.match?(~r/\p{Cc}/u, text),
        do: [question_text: "must not contain control characters"],
        else: []
    end)
    |> validate_inclusion(:outcome, @outcomes)
    |> foreign_key_constraint(:conversation_id)
    |> foreign_key_constraint(:project_id)
    |> unique_constraint([:conversation_id, :sequence],
      name: :project_assistant_turns_conversation_id_sequence_index
    )
    |> check_constraint(:sequence, name: :project_assistant_turns_sequence_positive)
    |> check_constraint(:outcome, name: :project_assistant_turns_outcome_check)
  end

  defp trim_question_text(changeset) do
    case fetch_change(changeset, :question_text) do
      {:ok, text} when is_binary(text) -> put_change(changeset, :question_text, String.trim(text))
      _other -> changeset
    end
  end
end
