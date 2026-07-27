defmodule SddOrchestrator.Devices.DeviceProject do
  @moduledoc """
  An accountless on-device project held in the device store.

  It carries only device-safe fields: a stable id, the user-chosen display name
  and its case-insensitive comparison key, the non-reversible repository
  fingerprint, the connection status, and the authoritative device storage mode.
  It never holds a local path, remote URL, filename, Git history, or source.
  """

  @enforce_keys [:id, :name, :name_key, :repository_fingerprint, :status]
  defstruct [
    :id,
    :name,
    :name_key,
    :repository_fingerprint,
    :status,
    :inserted_at,
    storage_mode: "device"
  ]

  @type t :: %__MODULE__{}
end
