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

  @doc "Corrects one device project display name without changing its stable identities."
  def rename_project(id, name) when is_binary(id) and is_binary(name),
    do: adapter().rename_project(id, name)

  @doc "Deletes a device project and all worker-owned project data."
  @spec delete_project(String.t()) ::
          {:ok,
           %{
             project_id: String.t(),
             deleted_specifications: non_neg_integer(),
             deleted_provenance: boolean(),
             deleted_repository_assessments: non_neg_integer(),
             deleted_repository_execution_profiles: non_neg_integer(),
             deleted_pilot_selection: boolean()
           }}
          | {:error, :not_found}
  def delete_project(id), do: adapter().delete_project(id)

  @doc "Finds a device project by its canonical repository fingerprint."
  @spec find_by_fingerprint(String.t()) :: {:ok, DeviceProject.t()} | {:error, :not_found}
  def find_by_fingerprint(fingerprint), do: adapter().find_by_fingerprint(fingerprint)

  @doc "Marks one exact canonical repository identity connected after normal authorization."
  def connect_repository(project_id, provider, repository_id) do
    adapter().connect_repository(project_id, provider, repository_id)
  end

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

  @doc "Stores one minimized repository assessment in the device authority."
  def put_repository_assessment(project_id, assessment_id, value) do
    adapter().put_repository_assessment(project_id, assessment_id, value)
  end

  @doc """
  Atomically moves one device assessment from its expected state to a terminal value.

  A completed transition carries the exact minimized proposal-envelope value and
  the adapter stores both or neither. An unsuccessful transition carries none.
  """
  def transition_repository_assessment(
        project_id,
        assessment_id,
        expected_state,
        value,
        envelope_value \\ nil
      ) do
    adapter().transition_repository_assessment(
      project_id,
      assessment_id,
      expected_state,
      value,
      envelope_value
    )
  end

  @doc "Reads one device-authoritative proposal-envelope value."
  def get_repository_assessment_proposal_envelope(project_id, assessment_id) do
    adapter().get_repository_assessment_proposal_envelope(project_id, assessment_id)
  end

  @doc "Reads one device-authoritative repository assessment value."
  def get_repository_assessment(project_id, assessment_id) do
    adapter().get_repository_assessment(project_id, assessment_id)
  end

  @doc "Counts one project's device-authoritative repository assessments."
  def repository_assessment_count(project_id) do
    adapter().repository_assessment_count(project_id)
  end

  @doc "Reads the newest device-authoritative repository assessment value."
  def latest_repository_assessment(project_id) do
    adapter().latest_repository_assessment(project_id)
  end

  @doc "Reads the newest completed device-authoritative repository assessment value."
  def latest_completed_repository_assessment(project_id) do
    adapter().latest_completed_repository_assessment(project_id)
  end

  @doc "Atomically appends one immutable device-authoritative profile version."
  def append_repository_execution_profile(
        project_id,
        assessment_id,
        proposal,
        approval_actor_ref,
        approved_at
      ) do
    adapter().append_repository_execution_profile(
      project_id,
      assessment_id,
      proposal,
      approval_actor_ref,
      approved_at
    )
  end

  @doc "Lists one project's immutable device-authoritative profile versions."
  def list_repository_execution_profiles(project_id) do
    adapter().list_repository_execution_profiles(project_id)
  end

  @doc "Stores one project's single current device-authoritative pilot selection."
  def put_repository_pilot_selection(project_id, value) do
    adapter().put_repository_pilot_selection(project_id, value)
  end

  @doc "Reads one project's current device-authoritative pilot selection."
  def get_repository_pilot_selection(project_id) do
    adapter().get_repository_pilot_selection(project_id)
  end

  @doc "Stores one vault-sealed device-local import attempt."
  def put_import_attempt(%ImportAttempt{} = attempt), do: adapter().put_import_attempt(attempt)

  @doc "Fetches one vault-sealed device-local import attempt."
  def get_import_attempt(id), do: adapter().get_import_attempt(id)

  @doc "Deletes one device-local import attempt and encrypted upload."
  def delete_import_attempt(id), do: adapter().delete_import_attempt(id)

  @doc "Deletes stranded device-local import attempts at the 24-hour boundary."
  def prune_import_attempts(%DateTime{} = now), do: adapter().prune_import_attempts(now)

  @doc "Fetches one project-bound device-local package provenance."
  def get_package_provenance(project_id), do: adapter().get_package_provenance(project_id)

  @doc """
  Applies one all-or-nothing batch of feature-delivery writes on the device.

  The worker owns the serialization boundary, so the batch is the device
  equivalent of one hosted transaction.
  """
  @spec commit_delivery(String.t(), list()) :: {:ok, map()} | {:error, term()}
  def commit_delivery(project_id, writes), do: adapter().commit_delivery(project_id, writes)

  @doc "Reads one device-authoritative delivery record."
  @spec get_delivery(String.t(), atom(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_delivery(project_id, kind, id), do: adapter().get_delivery(project_id, kind, id)

  @doc "Lists one project's device-authoritative delivery records of one kind."
  @spec list_delivery(String.t(), atom()) :: [map()]
  def list_delivery(project_id, kind), do: adapter().list_delivery(project_id, kind)

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
