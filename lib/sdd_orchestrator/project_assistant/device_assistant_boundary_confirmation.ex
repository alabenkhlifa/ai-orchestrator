defmodule SddOrchestrator.ProjectAssistant.DeviceAssistantBoundaryConfirmation do
  @moduledoc """
  Device-authoritative representation of one boundary-confirmation proof.

  Mirrors `DeviceProjectAssistantConversation`'s shape and reasoning: a
  device-authoritative project has no hosted owner or participant of its
  own, so its one implicit stable identity is the device workspace that owns
  the local store, keyed the same way (`id == workspace_id`). Stored through
  the same generic device-delivery seam every other device-authoritative
  record uses (`SddOrchestrator.Devices.commit_delivery/2` and friends),
  keyed by `:assistant_boundary_confirmation`.

  Carries no credential, exact quota, or provider diagnostic — only the
  stable digest, version, and confirmation time `ProcessingSummary` produces.
  """

  @enforce_keys [
    :id,
    :project_id,
    :workspace_id,
    :boundary_digest,
    :boundary_version,
    :confirmed_at,
    :state_version,
    :inserted_at,
    :updated_at
  ]
  defstruct [
    :id,
    :project_id,
    :workspace_id,
    :boundary_digest,
    :boundary_version,
    :confirmed_at,
    :state_version,
    :inserted_at,
    :updated_at
  ]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          project_id: Ecto.UUID.t(),
          workspace_id: Ecto.UUID.t(),
          boundary_digest: String.t(),
          boundary_version: pos_integer(),
          confirmed_at: DateTime.t(),
          state_version: pos_integer(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc "The device-delivery seam value shape."
  @spec to_value(t()) :: map()
  def to_value(%__MODULE__{} = confirmation) do
    %{
      "id" => confirmation.id,
      "project_id" => confirmation.project_id,
      "workspace_id" => confirmation.workspace_id,
      "boundary_digest" => confirmation.boundary_digest,
      "boundary_version" => confirmation.boundary_version,
      "confirmed_at" => DateTime.to_iso8601(confirmation.confirmed_at),
      "state_version" => confirmation.state_version,
      "inserted_at" => DateTime.to_iso8601(confirmation.inserted_at),
      "updated_at" => DateTime.to_iso8601(confirmation.updated_at)
    }
  end

  @spec from_value(map()) :: {:ok, t()} | {:error, :invalid_confirmation_value}
  def from_value(%{"state_version" => version} = value)
      when is_integer(version) and version > 0 do
    with true <-
           is_binary(value["id"]) and is_binary(value["project_id"]) and
             is_binary(value["workspace_id"]) and is_binary(value["boundary_digest"]),
         true <- is_integer(value["boundary_version"]) and value["boundary_version"] > 0,
         {:ok, confirmed_at, _offset} <- DateTime.from_iso8601(value["confirmed_at"] || ""),
         {:ok, inserted_at, _offset} <- DateTime.from_iso8601(value["inserted_at"] || ""),
         {:ok, updated_at, _offset} <- DateTime.from_iso8601(value["updated_at"] || "") do
      {:ok,
       %__MODULE__{
         id: value["id"],
         project_id: value["project_id"],
         workspace_id: value["workspace_id"],
         boundary_digest: value["boundary_digest"],
         boundary_version: value["boundary_version"],
         confirmed_at: confirmed_at,
         state_version: version,
         inserted_at: inserted_at,
         updated_at: updated_at
       }}
    else
      _invalid -> {:error, :invalid_confirmation_value}
    end
  end

  def from_value(_value), do: {:error, :invalid_confirmation_value}
end
