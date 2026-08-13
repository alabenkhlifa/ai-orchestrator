defmodule SddOrchestrator.RepositoryKits.InstallationStore do
  @moduledoc """
  Dual-authority persistence contract for one project's repository-kit
  installation.

  Dispatch follows the project's established storage authority, mirroring
  `RepositoryKits.ChangePlanStore` (Task 7). A device project never reaches
  PostgreSQL; a hosted project never reaches the device store. Unlike the
  change plan, an installation is mutable and single-row-per-project, so this
  contract carries two write operations — `create/2` for the initial install
  and `transition/3` for a later update or removal — instead of one, and two
  read operations: `current/2`, an authorized read used by
  `RepositoryKits.current_installation/3` that returns the installation in
  whatever state it holds (including `"removed"`, so the confirmation UI can
  still render it), and `raw/2`, an authority-routed but unauthenticated
  read used internally by `RepositoryKits` for its own already-authorized
  call sites (`plan_update/4`, `plan_removal/3`, and the idempotency check in
  `apply_plan/4`) — mirroring how the pre-Task-8 hosted-only code read
  `Repo.get_by(RepositoryKitInstallation, project_id: project_id)` directly,
  with no ownership check of its own, at every one of those call sites.
  """

  alias SddOrchestrator.Accounts.DeviceWorkspace
  alias SddOrchestrator.RepositoryKits.InstallationStore.{Device, Hosted}
  alias SddOrchestrator.RepositoryKits.RepositoryKitInstallation

  @type authority :: {:hosted, Ecto.UUID.t()} | {:device, DeviceWorkspace.t()}
  @type viewer :: authority() | {:participant, Ecto.UUID.t() | nil, Ecto.UUID.t()}

  @callback create(authority(), map()) ::
              {:ok, RepositoryKitInstallation.t()} | {:error, atom()}

  @callback transition(authority(), String.t(), map()) ::
              {:ok, RepositoryKitInstallation.t()} | {:error, atom()}

  @callback current(viewer(), String.t()) ::
              {:ok, RepositoryKitInstallation.t()} | {:error, :not_found}

  @callback raw(authority(), String.t()) ::
              {:ok, RepositoryKitInstallation.t()} | {:error, :not_found}

  @doc "Persists one newly-applied installation under the project's authoritative store."
  @spec create(authority(), map()) :: {:ok, RepositoryKitInstallation.t()} | {:error, atom()}
  def create({:hosted, _account_id} = authority, attrs), do: Hosted.create(authority, attrs)

  def create({:device, %DeviceWorkspace{}} = authority, attrs),
    do: Device.create(authority, attrs)

  def create(_authority, _attrs), do: {:error, :unsupported_authority}

  @doc "Overwrites the project's existing installation to reflect an update or removal plan."
  @spec transition(authority(), String.t(), map()) ::
          {:ok, RepositoryKitInstallation.t()} | {:error, atom()}
  def transition({:hosted, _account_id} = authority, project_id, attrs),
    do: Hosted.transition(authority, project_id, attrs)

  def transition({:device, %DeviceWorkspace{}} = authority, project_id, attrs),
    do: Device.transition(authority, project_id, attrs)

  def transition(_authority, _project_id, _attrs), do: {:error, :unsupported_authority}

  @doc "Reads the project's current installation, in whatever state it holds, for an authorized viewer."
  @spec current(viewer(), String.t()) ::
          {:ok, RepositoryKitInstallation.t()} | {:error, :not_found}
  def current({:hosted, _account_id} = viewer, project_id), do: Hosted.current(viewer, project_id)

  def current({:participant, _account_id, _hosted_identity_id} = viewer, project_id),
    do: Hosted.current(viewer, project_id)

  def current({:device, %DeviceWorkspace{}} = viewer, project_id),
    do: Device.current(viewer, project_id)

  def current(_viewer, _project_id), do: {:error, :not_found}

  @doc """
  Reads the project's current installation with no ownership check of its
  own, for a caller that has already authorized `authority` against
  `project_id` through its own separate check.
  """
  @spec raw(authority(), String.t()) ::
          {:ok, RepositoryKitInstallation.t()} | {:error, :not_found}
  def raw({:hosted, _account_id} = authority, project_id), do: Hosted.raw(authority, project_id)

  def raw({:device, %DeviceWorkspace{}} = authority, project_id),
    do: Device.raw(authority, project_id)

  def raw(_authority, _project_id), do: {:error, :not_found}
end
