defmodule SddOrchestrator.ProjectAssistant.DeviceProjectAssistantCitation do
  @moduledoc """
  Device-authoritative representation of one `ProjectAssistantCitation`.

  Mirrors the hosted observable contract without being an Ecto schema or
  creating any hosted persistence — the exact pairing convention
  `DeviceProjectAssistantTurn` already follows for its turn.

  `excerpt` is sealed with `SddOrchestrator.Vault` before it reaches this
  codec and opened again by the caller after, exactly like
  `DeviceProjectAssistantTurn.question_text` — the device store's file is
  not encrypted, so the store layer (not this struct) owns the
  encrypt/decrypt boundary.

  Stored through the same generic device-delivery seam every other
  device-authoritative record uses (`SddOrchestrator.Devices.commit_delivery/2`
  and friends), keyed by `:project_assistant_citation`.
  """

  @enforce_keys [:id, :turn_id, :project_id, :source_type, :reference, :inserted_at]
  defstruct [:id, :turn_id, :project_id, :source_type, :reference, :excerpt, :inserted_at]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          turn_id: Ecto.UUID.t(),
          project_id: Ecto.UUID.t(),
          source_type: String.t(),
          reference: map(),
          excerpt: String.t() | nil,
          inserted_at: DateTime.t()
        }

  @doc """
  The device-delivery seam value shape. `sealed_excerpt` is already
  Vault-encrypted, or `nil` when this citation carries no excerpt.
  """
  @spec to_value(t(), binary() | nil) :: map()
  def to_value(%__MODULE__{} = citation, sealed_excerpt) do
    %{
      "id" => citation.id,
      "turn_id" => citation.turn_id,
      "project_id" => citation.project_id,
      "source_type" => citation.source_type,
      "reference" => citation.reference,
      "excerpt" => sealed_excerpt,
      "inserted_at" => DateTime.to_iso8601(citation.inserted_at)
    }
  end

  @doc """
  Rebuilds one citation from its stored value and its already-decrypted
  excerpt (`nil` when the stored citation carries no excerpt).
  """
  @spec from_value(map(), String.t() | nil) :: {:ok, t()} | {:error, :invalid_citation_value}
  def from_value(%{} = value, decrypted_excerpt) do
    with true <-
           is_binary(value["id"]) and is_binary(value["turn_id"]) and
             is_binary(value["project_id"]),
         true <- is_binary(value["source_type"]) and is_map(value["reference"]),
         {:ok, inserted_at, _offset} <- DateTime.from_iso8601(value["inserted_at"] || "") do
      {:ok,
       %__MODULE__{
         id: value["id"],
         turn_id: value["turn_id"],
         project_id: value["project_id"],
         source_type: value["source_type"],
         reference: value["reference"],
         excerpt: decrypted_excerpt,
         inserted_at: inserted_at
       }}
    else
      _invalid -> {:error, :invalid_citation_value}
    end
  end

  def from_value(_value, _decrypted_excerpt), do: {:error, :invalid_citation_value}
end
