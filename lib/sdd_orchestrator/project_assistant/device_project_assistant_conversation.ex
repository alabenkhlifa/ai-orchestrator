defmodule SddOrchestrator.ProjectAssistant.DeviceProjectAssistantConversation do
  @moduledoc """
  Device-authoritative representation of one private conversation.

  Mirrors the hosted observable contract without being an Ecto schema or
  creating any hosted persistence. A device-authoritative project has no
  hosted owner or participant of its own, so its one implicit stable
  identity is the device workspace that owns the local store — there is
  never a second conversation to isolate `id == workspace_id` from.

  Stored through the same generic device-delivery seam every other
  device-authoritative record uses (`SddOrchestrator.Devices.commit_delivery/2`
  and friends), keyed by `:project_assistant_conversation`.
  """

  @enforce_keys [
    :id,
    :project_id,
    :workspace_id,
    :last_activity_at,
    :state_version,
    :inserted_at,
    :updated_at
  ]
  defstruct [
    :id,
    :project_id,
    :workspace_id,
    :last_activity_at,
    :state_version,
    :inserted_at,
    :updated_at
  ]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          project_id: Ecto.UUID.t(),
          workspace_id: Ecto.UUID.t(),
          last_activity_at: DateTime.t(),
          state_version: pos_integer(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc "The device-delivery seam value shape."
  @spec to_value(t()) :: map()
  def to_value(%__MODULE__{} = conversation) do
    %{
      "id" => conversation.id,
      "project_id" => conversation.project_id,
      "workspace_id" => conversation.workspace_id,
      "last_activity_at" => DateTime.to_iso8601(conversation.last_activity_at),
      "state_version" => conversation.state_version,
      "inserted_at" => DateTime.to_iso8601(conversation.inserted_at),
      "updated_at" => DateTime.to_iso8601(conversation.updated_at)
    }
  end

  @spec from_value(map()) :: {:ok, t()} | {:error, :invalid_conversation_value}
  def from_value(%{"state_version" => version} = value)
      when is_integer(version) and version > 0 do
    with true <-
           is_binary(value["id"]) and is_binary(value["project_id"]) and
             is_binary(value["workspace_id"]),
         {:ok, last_activity_at, _offset} <-
           DateTime.from_iso8601(value["last_activity_at"] || ""),
         {:ok, inserted_at, _offset} <- DateTime.from_iso8601(value["inserted_at"] || ""),
         {:ok, updated_at, _offset} <- DateTime.from_iso8601(value["updated_at"] || "") do
      {:ok,
       %__MODULE__{
         id: value["id"],
         project_id: value["project_id"],
         workspace_id: value["workspace_id"],
         last_activity_at: last_activity_at,
         state_version: version,
         inserted_at: inserted_at,
         updated_at: updated_at
       }}
    else
      _invalid -> {:error, :invalid_conversation_value}
    end
  end

  def from_value(_value), do: {:error, :invalid_conversation_value}
end
