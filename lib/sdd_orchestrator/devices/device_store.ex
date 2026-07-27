defmodule SddOrchestrator.Devices.DeviceStore do
  @moduledoc """
  The device-side persistence contract for accountless on-device data.

  Device-authoritative data — the device workspace and its projects — lives under
  the current operating-system boundary and never in the hosted control-plane
  database. The native macOS worker provides the production adapter
  (release-gated); `SddOrchestrator.Devices.DeviceStore.Local` backs development
  and verification.
  """

  alias SddOrchestrator.Accounts.DeviceWorkspace
  alias SddOrchestrator.Devices.DeviceProject

  @doc "Returns the established device workspace, creating it if none exists."
  @callback establish_workspace() :: {:ok, DeviceWorkspace.t()} | {:error, term()}

  @doc "Returns the established device workspace, or `{:error, :not_found}` after loss."
  @callback get_workspace() :: {:ok, DeviceWorkspace.t()} | {:error, :not_found}

  @doc "Atomically registers one device project under the workspace naming and uniqueness rules."
  @callback register_project(map(), keyword()) :: {:ok, DeviceProject.t()} | {:error, term()}

  @doc "Lists the device projects, ordered by display name."
  @callback list_projects() :: [DeviceProject.t()]

  @doc "Fetches one device project by id."
  @callback get_project(String.t()) :: {:ok, DeviceProject.t()} | {:error, :not_found}

  @doc "Finds a device project by its canonical repository fingerprint, for reconnection."
  @callback find_by_fingerprint(String.t()) :: {:ok, DeviceProject.t()} | {:error, :not_found}
end
