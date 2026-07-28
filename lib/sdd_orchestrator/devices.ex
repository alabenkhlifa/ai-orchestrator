defmodule SddOrchestrator.Devices do
  @moduledoc """
  The accountless on-device persistence boundary for local project onboarding.

  All device-authoritative data is owned by the current operating-system user and
  filesystem boundary and is served through the configured `DeviceStore` adapter,
  never the hosted database. If that device data is lost there is no hosted copy
  to restore; recovery requires a previous export (`specs/06-project-portability`).
  """

  alias SddOrchestrator.Accounts.DeviceWorkspace

  alias SddOrchestrator.Devices.{
    DeviceProject,
    DeviceTransaction,
    Pairing,
    PortableRepositoryIdentity,
    WorkerDiscovery
  }

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

  @doc """
  Selects a repository for new onboarding through the worker identity boundary.

  Every identity already authorized to this device workspace is compared before a
  fresh portable identity is allocated. A match returns the existing project and
  no new identity; otherwise the result contains only the new canonical
  fingerprint. Repository paths and Git metadata never leave this function.
  """
  @spec select_repository(Path.t(), DeviceWorkspace.t()) ::
          {:ok, %{fingerprint: String.t()}}
          | {:error,
             SddOrchestrator.Devices.RepositoryValidation.error()
             | {:repository_already_linked, DeviceProject.t()}}
  def select_repository(path, %DeviceWorkspace{id: workspace_id}) do
    projects = list_projects()

    with :ok <- ensure_repository_unlinked(path, projects, workspace_id),
         {:ok, fingerprint} <- PortableRepositoryIdentity.generate(path) do
      {:ok, %{fingerprint: fingerprint}}
    end
  end

  @doc """
  Reconnects a portable identity or atomically upgrades a matching legacy
  identity after explicit source-side selection.

  Legacy upgrade rechecks the exact set of other identities compared by the
  worker before replacing the stored value. A concurrent project or identity
  change returns `:identity_race` and leaves the project unchanged.
  """
  @spec locate_repository(Path.t(), DeviceProject.t(), DeviceWorkspace.t()) ::
          {:ok, %{project: DeviceProject.t(), upgraded?: boolean()}}
          | {:error,
             :repository_mismatch
             | :invalid_repository_identity
             | :identity_changed
             | :identity_race
             | SddOrchestrator.Devices.RepositoryValidation.error()
             | {:repository_already_linked, DeviceProject.t()}}
  def locate_repository(path, %DeviceProject{} = project, %DeviceWorkspace{} = workspace) do
    locate_repository_with_hook(path, project, workspace, fn _replacement_identity -> :ok end)
  end

  @doc false
  def locate_repository_with_hook(
        path,
        %DeviceProject{} = project,
        %DeviceWorkspace{id: workspace_id},
        before_replace
      )
      when is_function(before_replace, 1) do
    case PortableRepositoryIdentity.parse(project.repository_fingerprint) do
      {:ok, _portable} ->
        case PortableRepositoryIdentity.match(path, project.repository_fingerprint) do
          {:ok, true} -> {:ok, %{project: project, upgraded?: false}}
          {:ok, false} -> {:error, :repository_mismatch}
          {:error, reason} -> {:error, reason}
        end

      {:error, :legacy_identifier} ->
        upgrade_legacy_repository(path, project, workspace_id, before_replace)

      {:error, :invalid_identifier} ->
        {:error, :invalid_repository_identity}
    end
  end

  @doc """
  Reports whether a project's canonical identity is ready for exact
  replacement-environment matching in a future portability package.
  """
  @spec repository_backup_readiness(DeviceProject.t()) :: :backup_ready | :upgrade_required
  def repository_backup_readiness(%DeviceProject{repository_fingerprint: fingerprint}) do
    case PortableRepositoryIdentity.parse(fingerprint) do
      {:ok, _portable} -> :backup_ready
      {:error, _legacy_or_invalid} -> :upgrade_required
    end
  end

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

  @doc "Commits a caller-owned transaction through the device worker boundary."
  @spec commit_transaction(DeviceTransaction.t()) :: {:ok, map()} | {:error, term()}
  def commit_transaction(%DeviceTransaction{} = transaction) do
    adapter().commit_transaction(transaction)
  end

  defp adapter do
    Application.fetch_env!(:sdd_orchestrator, __MODULE__)[:adapter]
  end

  defp upgrade_legacy_repository(path, project, workspace_id, before_replace) do
    with {:ok, true} <-
           PortableRepositoryIdentity.match_legacy(
             path,
             project.repository_fingerprint,
             workspace_id
           ),
         other_projects = Enum.reject(list_projects(), &(&1.id == project.id)),
         :ok <- ensure_repository_unlinked(path, other_projects, workspace_id),
         comparison_snapshot =
           Map.new(other_projects, &{&1.id, &1.repository_fingerprint}),
         {:ok, replacement_identity} <- PortableRepositoryIdentity.generate(path),
         :ok <- before_replace.(replacement_identity),
         {:ok, upgraded} <-
           adapter().replace_repository_identity(
             project.id,
             project.repository_fingerprint,
             replacement_identity,
             comparison_snapshot
           ) do
      {:ok, %{project: upgraded, upgraded?: true}}
    else
      {:ok, false} -> {:error, :repository_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_repository_unlinked(path, projects, workspace_id) do
    Enum.reduce_while(projects, :ok, fn project, :ok ->
      case matches_repository?(path, project.repository_fingerprint, workspace_id) do
        {:ok, true} ->
          {:halt, {:error, {:repository_already_linked, project}}}

        {:ok, false} ->
          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp matches_repository?(path, identity, workspace_id) do
    case PortableRepositoryIdentity.parse(identity) do
      {:ok, _portable} ->
        PortableRepositoryIdentity.match(path, identity)

      {:error, :legacy_identifier} ->
        PortableRepositoryIdentity.match_legacy(path, identity, workspace_id)

      # Pre-contract development records may contain non-canonical placeholders.
      # They cannot authorize a match and are never treated as portable.
      {:error, :invalid_identifier} ->
        {:ok, false}
    end
  end
end
