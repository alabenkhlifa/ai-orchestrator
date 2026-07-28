defmodule SddOrchestrator.Devices do
  @moduledoc """
  The accountless on-device persistence boundary for local project onboarding.

  All device-authoritative data is owned by the current operating-system user and
  filesystem boundary and is served through the configured `DeviceStore` adapter,
  never the hosted database. If that device data is lost there is no hosted copy
  to restore; recovery requires a previous export (`specs/06-project-portability`).
  """

  alias SddOrchestrator.Accounts.DeviceWorkspace
  alias SddOrchestrator.Devices.{DeviceProject, DeviceTransaction, Pairing, WorkerDiscovery}
  alias SddOrchestrator.Portability.ImportAttempt

  @doc "Returns the established accountless device workspace, creating it if absent."
  @spec establish_workspace() :: {:ok, DeviceWorkspace.t()} | {:error, term()}
  def establish_workspace, do: adapter().establish_workspace()

  @doc """
  Reports the local worker discovery status for a device workspace.

  Combines the workspace's active paired workers with the compatibility and
  reachability policy in `WorkerDiscovery`, returning `:missing`,
  `:incompatible`, `:unavailable`, or `:detected` so the onboarding UI can guide
  installation, pairing, or repository selection.
  """
  @spec worker_status(Ecto.UUID.t()) :: WorkerDiscovery.status()
  def worker_status(device_workspace_id) do
    device_workspace_id
    |> Pairing.active_workers()
    |> WorkerDiscovery.status()
  end

  @doc "Returns the established device workspace, or `{:error, :not_found}` after loss."
  @spec get_workspace() :: {:ok, DeviceWorkspace.t()} | {:error, :not_found}
  def get_workspace, do: adapter().get_workspace()

  @doc """
  Registers one device project. `attrs` carries the user-chosen `:name`, the
  `:repository_fingerprint`, and the connection `:status`. With
  `allocate_suffix?: true`, a name collision takes the next available suffix
  instead of failing.
  """
  @spec register_project(map(), keyword()) :: {:ok, DeviceProject.t()} | {:error, term()}
  def register_project(attrs, opts \\ []) when is_map(attrs),
    do: adapter().register_project(attrs, opts)

  @doc "Lists the device projects, ordered by display name."
  @spec list_projects() :: [DeviceProject.t()]
  def list_projects, do: adapter().list_projects()

  @doc "Fetches one device project by id."
  @spec get_project(String.t()) :: {:ok, DeviceProject.t()} | {:error, :not_found}
  def get_project(id), do: adapter().get_project(id)

  @doc "Deletes a device project and all worker-owned project data."
  @spec delete_project(String.t()) ::
          {:ok, %{project_id: String.t(), deleted_specifications: non_neg_integer()}}
          | {:error, :not_found}
  def delete_project(id), do: adapter().delete_project(id)

  @doc "Finds a device project by its canonical repository fingerprint."
  @spec find_by_fingerprint(String.t()) :: {:ok, DeviceProject.t()} | {:error, :not_found}
  def find_by_fingerprint(fingerprint), do: adapter().find_by_fingerprint(fingerprint)

  @doc "Atomically creates one device-authoritative specification aggregate."
  def create_specification(project_id, specification, revision) do
    adapter().create_specification(project_id, specification, revision)
  end

  @doc "Atomically appends one device-authoritative specification revision."
  def append_specification_revision(
        project_id,
        specification_id,
        expected_revision_id,
        revision,
        specification_attrs
      ) do
    adapter().append_specification_revision(
      project_id,
      specification_id,
      expected_revision_id,
      revision,
      specification_attrs
    )
  end

  @doc "Returns one device-authoritative specification and current revision."
  def get_current_specification(project_id, specification_id) do
    adapter().get_current_specification(project_id, specification_id)
  end

  @doc "Counts the device-authoritative specifications for one project."
  def specification_count(project_id), do: adapter().specification_count(project_id)

  @doc "Returns all current device-authoritative specifications for one project."
  def current_specifications(project_id), do: adapter().current_specifications(project_id)

  @doc "Stores one vault-sealed device-local import attempt."
  def put_import_attempt(%ImportAttempt{} = attempt), do: adapter().put_import_attempt(attempt)

  @doc "Fetches one vault-sealed device-local import attempt."
  def get_import_attempt(id), do: adapter().get_import_attempt(id)

  @doc "Deletes one device-local import attempt and encrypted upload."
  def delete_import_attempt(id), do: adapter().delete_import_attempt(id)

  @doc "Fetches one project-bound device-local package provenance."
  def get_package_provenance(project_id), do: adapter().get_package_provenance(project_id)

  @doc "Commits a caller-owned transaction through the device worker boundary."
  @spec commit_transaction(DeviceTransaction.t()) :: {:ok, map()} | {:error, term()}
  def commit_transaction(%DeviceTransaction{} = transaction) do
    adapter().commit_transaction(transaction)
  end

  defp adapter do
    Application.fetch_env!(:sdd_orchestrator, __MODULE__)[:adapter]
  end
end
