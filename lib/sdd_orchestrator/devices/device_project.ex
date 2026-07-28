defmodule SddOrchestrator.Devices.DeviceProject do
  @moduledoc """
  An accountless on-device project held in the device store.

  It carries only device-safe fields: a stable id, the user-chosen display name
  and its case-insensitive comparison key, the non-reversible repository
  fingerprint, the connection status, and the authoritative device storage mode.
  It never holds a local path, remote URL, filename, Git history, or source.

  `idempotency_key` is the transient onboarding attempt's key. It makes device
  registration idempotent: a committed retry or a lost control-plane
  acknowledgement resolves to the already-created project instead of a duplicate.
  """

  @enforce_keys [
    :id,
    :workspace_id,
    :name,
    :name_key,
    :repository_provider,
    :repository_id,
    :status
  ]
  defstruct [
    :id,
    :workspace_id,
    :name,
    :name_key,
    :repository_provider,
    :repository_id,
    :repository_fingerprint,
    :status,
    :inserted_at,
    :idempotency_key,
    storage_mode: "device"
  ]

  @type t :: %__MODULE__{}
end
