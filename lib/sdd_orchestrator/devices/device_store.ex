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
  alias SddOrchestrator.Devices.{DeviceProject, DeviceTransaction}
  alias SddOrchestrator.SpecificationStore

  alias SddOrchestrator.Specifications.{
    DeviceProjectSpecification,
    DeviceSpecificationRevision
  }

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

  @doc "Deletes one device project and every device-authoritative specification aggregate."
  @callback delete_project(String.t()) ::
              {:ok, %{project_id: String.t(), deleted_specifications: non_neg_integer()}}
              | {:error, :not_found}

  @doc "Finds a device project by its canonical repository fingerprint, for reconnection."
  @callback find_by_fingerprint(String.t()) :: {:ok, DeviceProject.t()} | {:error, :not_found}

  @doc "Atomically creates one specification and its first complete revision."
  @callback create_specification(
              String.t(),
              DeviceProjectSpecification.t(),
              DeviceSpecificationRevision.t()
            ) :: {:ok, SpecificationStore.current()} | {:error, term()}

  @doc "Atomically appends and advances one expected specification head."
  @callback append_specification_revision(
              String.t(),
              String.t(),
              String.t(),
              DeviceSpecificationRevision.t(),
              map()
            ) :: {:ok, SpecificationStore.current()} | {:error, term()}

  @doc "Returns one device-authoritative specification and its current revision."
  @callback get_current_specification(String.t(), String.t()) ::
              {:ok, SpecificationStore.current()} | {:error, :not_found}

  @doc "Counts the device-authoritative specifications for one project."
  @callback specification_count(String.t()) :: non_neg_integer()

  @doc "Returns all current device-authoritative specifications for one project."
  @callback current_specifications(String.t()) :: [SpecificationStore.current()]

  @doc "Commits the supported contributions in one worker-owned device transaction."
  @callback commit_transaction(DeviceTransaction.t()) ::
              {:ok, map()} | {:error, term()}
end
