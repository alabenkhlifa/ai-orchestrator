defmodule SddOrchestrator.Devices do
  @moduledoc """
  The accountless on-device persistence boundary for local project onboarding.

  All device-authoritative data is owned by the current operating-system user and
  filesystem boundary and is served through the configured `DeviceStore` adapter,
  never the hosted database. If that device data is lost there is no hosted copy
  to restore; recovery requires a previous export (`specs/06-project-portability`).
  """

  alias SddOrchestrator.Accounts.DeviceWorkspace

  @doc "Returns the established accountless device workspace, creating it if absent."
  @spec establish_workspace() :: {:ok, DeviceWorkspace.t()} | {:error, term()}
  def establish_workspace, do: adapter().establish_workspace()

  @doc "Returns the established device workspace, or `{:error, :not_found}` after loss."
  @spec get_workspace() :: {:ok, DeviceWorkspace.t()} | {:error, :not_found}
  def get_workspace, do: adapter().get_workspace()

  defp adapter do
    Application.fetch_env!(:sdd_orchestrator, __MODULE__)[:adapter]
  end
end
