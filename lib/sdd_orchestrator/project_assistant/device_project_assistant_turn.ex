defmodule SddOrchestrator.ProjectAssistant.DeviceProjectAssistantTurn do
  @moduledoc """
  Device-authoritative representation of one private, ordered turn.

  Mirrors the hosted observable contract without being an Ecto schema or
  creating any hosted persistence. Carries no `state_version`, like an
  artifact: a turn is written once and never rewritten, so every write
  expects no prior stored version.

  The question text is sealed with `SddOrchestrator.Vault` before it reaches
  this codec and opened again by the caller after — the device store's file
  is not encrypted, so the store layer (not this struct) owns the
  encrypt/decrypt boundary, the same treatment a device-local artifact gets.

  Task 7 extends this shape with the answer, the stored-context version it
  grounded on, uncertainty markers, and a normalized outcome — mirroring the
  hosted `ProjectAssistantTurn` extension field for field. `answer_text` gets
  the same Vault-sealed treatment as `question_text`, through the new
  `to_value/3` and `from_value/3` clauses added alongside (never replacing)
  Task 1's original `to_value/2` and `from_value/2`, so
  `ProjectAssistantStore.Device`'s existing question-only read and write path
  keeps working unmodified. `SddOrchestrator.ProjectAssistant.TurnAnswerStore.Device`
  is the only caller of the new 3-arity clauses.
  """

  @enforce_keys [:id, :conversation_id, :project_id, :sequence, :question_text, :inserted_at]
  defstruct [
    :id,
    :conversation_id,
    :project_id,
    :sequence,
    :question_text,
    :inserted_at,
    :answer_text,
    :context_version,
    :outcome,
    :failure_reason,
    uncertainty_markers: []
  ]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          conversation_id: Ecto.UUID.t(),
          project_id: Ecto.UUID.t(),
          sequence: pos_integer(),
          question_text: String.t(),
          inserted_at: DateTime.t(),
          answer_text: String.t() | nil,
          context_version: String.t() | nil,
          uncertainty_markers: [map()],
          outcome: String.t() | nil,
          failure_reason: String.t() | nil
        }

  @doc "The device-delivery seam value shape. `sealed_question_text` is already Vault-encrypted."
  @spec to_value(t(), binary()) :: map()
  def to_value(%__MODULE__{} = turn, sealed_question_text) do
    %{
      "id" => turn.id,
      "conversation_id" => turn.conversation_id,
      "project_id" => turn.project_id,
      "sequence" => turn.sequence,
      "question_text" => sealed_question_text,
      "inserted_at" => DateTime.to_iso8601(turn.inserted_at)
    }
  end

  @doc """
  The device-delivery seam value shape for one fully answered, cancelled, or
  failed turn. `sealed_question_text` and `sealed_answer_text` are already
  Vault-encrypted; `sealed_answer_text` is `nil` when the turn carries no
  answer (a failed or cancelled outcome).
  """
  @spec to_value(t(), binary(), binary() | nil) :: map()
  def to_value(%__MODULE__{} = turn, sealed_question_text, sealed_answer_text) do
    turn
    |> to_value(sealed_question_text)
    |> Map.merge(%{
      "answer_text" => sealed_answer_text,
      "context_version" => turn.context_version,
      "uncertainty_markers" => turn.uncertainty_markers || [],
      "outcome" => turn.outcome,
      "failure_reason" => turn.failure_reason
    })
  end

  @doc "Rebuilds one turn from its stored value and its already-decrypted question text."
  @spec from_value(map(), String.t()) :: {:ok, t()} | {:error, :invalid_turn_value}
  def from_value(%{} = value, decrypted_question_text) when is_binary(decrypted_question_text) do
    with {:ok, base} <- base_fields(value) do
      {:ok, struct!(__MODULE__, Map.put(base, :question_text, decrypted_question_text))}
    end
  end

  def from_value(_value, _decrypted_question_text), do: {:error, :invalid_turn_value}

  @doc """
  Rebuilds one fully answered, cancelled, or failed turn from its stored
  value and its already-decrypted question and answer text.
  `decrypted_answer_text` is `nil` when the stored turn carries no answer.
  """
  @spec from_value(map(), String.t(), String.t() | nil) ::
          {:ok, t()} | {:error, :invalid_turn_value}
  def from_value(%{} = value, decrypted_question_text, decrypted_answer_text)
      when is_binary(decrypted_question_text) do
    with {:ok, base} <- base_fields(value) do
      {:ok,
       struct!(
         __MODULE__,
         Map.merge(base, %{
           question_text: decrypted_question_text,
           answer_text: decrypted_answer_text,
           context_version: value["context_version"],
           uncertainty_markers: value["uncertainty_markers"] || [],
           outcome: value["outcome"],
           failure_reason: value["failure_reason"]
         })
       )}
    end
  end

  def from_value(_value, _decrypted_question_text, _decrypted_answer_text),
    do: {:error, :invalid_turn_value}

  defp base_fields(value) do
    with true <-
           is_binary(value["id"]) and is_binary(value["conversation_id"]) and
             is_binary(value["project_id"]),
         true <- is_integer(value["sequence"]) and value["sequence"] > 0,
         {:ok, inserted_at, _offset} <- DateTime.from_iso8601(value["inserted_at"] || "") do
      {:ok,
       %{
         id: value["id"],
         conversation_id: value["conversation_id"],
         project_id: value["project_id"],
         sequence: value["sequence"],
         inserted_at: inserted_at
       }}
    else
      _invalid -> {:error, :invalid_turn_value}
    end
  end
end
