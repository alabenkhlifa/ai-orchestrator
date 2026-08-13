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
  """

  @enforce_keys [:id, :conversation_id, :project_id, :sequence, :question_text, :inserted_at]
  defstruct [:id, :conversation_id, :project_id, :sequence, :question_text, :inserted_at]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          conversation_id: Ecto.UUID.t(),
          project_id: Ecto.UUID.t(),
          sequence: pos_integer(),
          question_text: String.t(),
          inserted_at: DateTime.t()
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

  @doc "Rebuilds one turn from its stored value and its already-decrypted question text."
  @spec from_value(map(), String.t()) :: {:ok, t()} | {:error, :invalid_turn_value}
  def from_value(%{} = value, decrypted_question_text) when is_binary(decrypted_question_text) do
    with true <-
           is_binary(value["id"]) and is_binary(value["conversation_id"]) and
             is_binary(value["project_id"]),
         true <- is_integer(value["sequence"]) and value["sequence"] > 0,
         {:ok, inserted_at, _offset} <- DateTime.from_iso8601(value["inserted_at"] || "") do
      {:ok,
       %__MODULE__{
         id: value["id"],
         conversation_id: value["conversation_id"],
         project_id: value["project_id"],
         sequence: value["sequence"],
         question_text: decrypted_question_text,
         inserted_at: inserted_at
       }}
    else
      _invalid -> {:error, :invalid_turn_value}
    end
  end

  def from_value(_value, _decrypted_question_text), do: {:error, :invalid_turn_value}
end
