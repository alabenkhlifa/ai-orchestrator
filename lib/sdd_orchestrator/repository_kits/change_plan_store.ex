defmodule SddOrchestrator.RepositoryKits.ChangePlanStore do
  @moduledoc """
  Dual-authority persistence contract for one project's repository-kit
  change plan.

  Dispatch follows the project's established storage authority, mirroring
  `RepositoryAssessments.ProfileStore`. A device project never reaches
  PostgreSQL; a hosted project never reaches the device store.
  """

  alias SddOrchestrator.Accounts.DeviceWorkspace
  alias SddOrchestrator.RepositoryKits.ChangePlanStore.{Device, Hosted}
  alias SddOrchestrator.RepositoryKits.RepositoryKitChangePlan

  @type authority :: {:hosted, Ecto.UUID.t()} | {:device, DeviceWorkspace.t()}
  @type viewer :: authority() | {:participant, Ecto.UUID.t() | nil, Ecto.UUID.t()}

  @callback create(authority(), map()) ::
              {:ok, RepositoryKitChangePlan.t()} | {:error, atom()}

  @callback current(viewer(), String.t(), DateTime.t()) ::
              {:ok, RepositoryKitChangePlan.t()} | {:error, :not_found}

  @callback get(authority(), String.t(), String.t()) ::
              {:ok, RepositoryKitChangePlan.t()} | {:error, :not_found}

  @doc "Persists one worker-built change plan under the project's authoritative store."
  @spec create(authority(), map()) :: {:ok, RepositoryKitChangePlan.t()} | {:error, atom()}
  def create({:hosted, _account_id} = authority, attrs), do: Hosted.create(authority, attrs)

  def create({:device, %DeviceWorkspace{}} = authority, attrs),
    do: Device.create(authority, attrs)

  def create(_authority, _attrs), do: {:error, :unsupported_authority}

  @doc "Reads the project's current (most recent, non-expired) change plan."
  @spec current(viewer(), String.t(), DateTime.t()) ::
          {:ok, RepositoryKitChangePlan.t()} | {:error, :not_found}
  def current({:hosted, _account_id} = viewer, project_id, now),
    do: Hosted.current(viewer, project_id, now)

  def current({:participant, _account_id, _hosted_identity_id} = viewer, project_id, now),
    do: Hosted.current(viewer, project_id, now)

  def current({:device, %DeviceWorkspace{}} = viewer, project_id, now),
    do: Device.current(viewer, project_id, now)

  def current(_viewer, _project_id, _now), do: {:error, :not_found}

  @doc """
  Fetches one exact plan by id, for `apply_plan/4`'s own authority-agnostic
  apply logic — unlike `current/3`, not restricted to the most recent
  non-expired plan, since a caller here already has one specific `plan_id`
  in hand and needs exactly that plan, whatever its expiry state (expiry is
  a separate gate `apply_plan/4` checks on its own).
  """
  @spec get(authority(), String.t(), String.t()) ::
          {:ok, RepositoryKitChangePlan.t()} | {:error, :not_found}
  def get({:hosted, _account_id} = authority, project_id, plan_id),
    do: Hosted.get(authority, project_id, plan_id)

  def get({:device, %DeviceWorkspace{}} = authority, project_id, plan_id),
    do: Device.get(authority, project_id, plan_id)

  def get(_authority, _project_id, _plan_id), do: {:error, :not_found}
end
