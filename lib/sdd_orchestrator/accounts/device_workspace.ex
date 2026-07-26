defmodule SddOrchestrator.Accounts.DeviceWorkspace do
  @moduledoc """
  The device-local one-to-one profile of a device `Workspace`.

  This value is a persistence contract, not a hosted schema. It contains no
  account, user, device label, operating-system username, local path, hardware
  identifier, or source data. The future worker adapter persists the profile and
  its projects under the current operating-system boundary.
  """

  alias SddOrchestrator.Accounts.Workspace
  alias SddOrchestrator.ProjectStorage.StorageMode

  @enforce_keys [:id]
  defstruct [:id]

  @type t :: %__MODULE__{id: Ecto.UUID.t()}

  @doc "Creates the one-to-one device profile for a device logical root."
  @spec from_workspace(Workspace.t()) :: {:ok, t()} | {:error, :not_device_workspace}
  def from_workspace(%Workspace{id: id, kind: "device"}) when is_binary(id),
    do: {:ok, %__MODULE__{id: id}}

  def from_workspace(_workspace), do: {:error, :not_device_workspace}

  @doc """
  Checks device ownership without consulting or attaching a hosted identity.

  Signing in cannot change the result because ownership is derived only from the
  device workspace id and the project's authoritative storage mode.
  """
  @spec owns_project?(t(), map()) :: boolean()
  def owns_project?(%__MODULE__{id: id}, %{workspace_id: id, storage_mode: mode}),
    do: StorageMode.cast(mode) == {:ok, "device"}

  def owns_project?(_workspace, _project), do: false
end
