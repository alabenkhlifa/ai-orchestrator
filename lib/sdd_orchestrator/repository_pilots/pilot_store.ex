defmodule SddOrchestrator.RepositoryPilots.PilotStore do
  @moduledoc """
  Authoritative storage contract for one project's current pilot selection.

  Dispatch follows the project's established storage authority. A device project
  never falls back to PostgreSQL, so a device-authoritative pilot leaves no
  hosted copy behind. Each function fails closed on an authority it does not
  recognize.
  """

  alias SddOrchestrator.Accounts.DeviceWorkspace
  alias SddOrchestrator.RepositoryPilots.PilotStore.{Device, Hosted}
  alias SddOrchestrator.RepositoryPilots.RepositoryPilotSelection

  @type authority :: {:hosted, Ecto.UUID.t()} | {:device, DeviceWorkspace.t()}
  @type viewer :: authority() | {:participant, Ecto.UUID.t() | nil, Ecto.UUID.t()}

  @callback put(authority(), RepositoryPilotSelection.t()) ::
              {:ok, RepositoryPilotSelection.t()} | {:error, atom() | Ecto.Changeset.t()}

  @callback fetch(viewer(), Ecto.UUID.t()) ::
              {:ok, RepositoryPilotSelection.t()} | {:error, :not_found}

  @doc "Stores the project's single current pilot, replacing any prior one."
  @spec put(authority(), RepositoryPilotSelection.t()) ::
          {:ok, RepositoryPilotSelection.t()} | {:error, atom() | Ecto.Changeset.t()}
  def put({:hosted, _account_id} = authority, %RepositoryPilotSelection{} = selection),
    do: Hosted.put(authority, selection)

  def put({:device, %DeviceWorkspace{}} = authority, %RepositoryPilotSelection{} = selection),
    do: Device.put(authority, selection)

  def put(_authority, _selection), do: {:error, :unsupported_authority}

  @doc "Reads the current pilot a hosted owner, participant, or device may see."
  @spec fetch(viewer(), Ecto.UUID.t()) ::
          {:ok, RepositoryPilotSelection.t()} | {:error, :not_found}
  def fetch({:hosted, _account_id} = viewer, project_id), do: Hosted.fetch(viewer, project_id)

  def fetch({:participant, _account_id, _identity_id} = viewer, project_id),
    do: Hosted.fetch(viewer, project_id)

  def fetch({:device, %DeviceWorkspace{}} = viewer, project_id),
    do: Device.fetch(viewer, project_id)

  def fetch(_viewer, _project_id), do: {:error, :not_found}
end
