defmodule SddOrchestrator.ProjectAssistant.DeviceProjectContextProjection do
  @moduledoc """
  The device-authoritative shape of `ProjectContextProjection`.

  Goes through the same generic device-delivery seam every other
  device-authoritative record uses (`SddOrchestrator.Devices.commit_delivery/2`
  and friends), keyed by the project id itself: there is exactly one
  projection per device-authoritative project, the device equivalent of the
  hosted table's `unique_index` on `project_id`.

  `content` never carries a specification document body, repository path,
  source, source index, prior revision, or raw run log — see
  `ProjectContextProjection`'s moduledoc for why.
  """

  @enforce_keys [
    :id,
    :project_id,
    :context_version,
    :content,
    :refreshed_at,
    :state_version
  ]
  defstruct [
    :id,
    :project_id,
    :context_version,
    :content,
    :refreshed_at,
    :state_version,
    :inserted_at,
    :updated_at
  ]

  @type t :: %__MODULE__{}

  @spec to_value(t()) :: map()
  def to_value(%__MODULE__{} = projection) do
    %{
      "id" => projection.id,
      "project_id" => projection.project_id,
      "context_version" => projection.context_version,
      "content" => projection.content,
      "refreshed_at" => DateTime.to_iso8601(projection.refreshed_at),
      "state_version" => projection.state_version,
      "inserted_at" => DateTime.to_iso8601(projection.inserted_at || projection.refreshed_at),
      "updated_at" => DateTime.to_iso8601(projection.updated_at || projection.refreshed_at)
    }
  end

  @spec from_value(map()) :: {:ok, t()} | {:error, :invalid_projection_value}
  def from_value(%{} = value) do
    with true <- is_binary(value["id"]) and is_binary(value["project_id"]),
         true <- is_binary(value["context_version"]) and is_map(value["content"]),
         true <- is_integer(value["state_version"]) and value["state_version"] > 0,
         {:ok, refreshed_at, _offset} <- DateTime.from_iso8601(value["refreshed_at"] || ""),
         {:ok, inserted_at} <- optional_datetime(value["inserted_at"], refreshed_at),
         {:ok, updated_at} <- optional_datetime(value["updated_at"], refreshed_at) do
      {:ok,
       %__MODULE__{
         id: value["id"],
         project_id: value["project_id"],
         context_version: value["context_version"],
         content: value["content"],
         refreshed_at: refreshed_at,
         state_version: value["state_version"],
         inserted_at: inserted_at,
         updated_at: updated_at
       }}
    else
      _invalid -> {:error, :invalid_projection_value}
    end
  end

  def from_value(_value), do: {:error, :invalid_projection_value}

  defp optional_datetime(nil, fallback), do: {:ok, fallback}

  defp optional_datetime(iso8601, _fallback) when is_binary(iso8601) do
    case DateTime.from_iso8601(iso8601) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, _reason} -> :error
    end
  end

  defp optional_datetime(_other, _fallback), do: :error
end
