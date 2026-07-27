defmodule SddOrchestrator.Devices.DeviceStore do
  @moduledoc """
  The device-side persistence contract for accountless on-device data.

  Device-authoritative data lives under the current operating-system boundary and
  never in the hosted control-plane database. The native macOS worker provides the
  production adapter (release-gated); `SddOrchestrator.Devices.DeviceStore.Local`
  backs development and verification.
  """

  alias SddOrchestrator.Accounts.DeviceWorkspace

  @doc "Returns the established device workspace, creating it if none exists."
  @callback establish_workspace() :: {:ok, DeviceWorkspace.t()} | {:error, term()}

  @doc "Returns the established device workspace, or `{:error, :not_found}` after loss."
  @callback get_workspace() :: {:ok, DeviceWorkspace.t()} | {:error, :not_found}
end
