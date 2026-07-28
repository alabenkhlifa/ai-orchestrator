defmodule SddOrchestrator.SpecificationStore do
  @moduledoc """
  Shared authoritative specification-store interface.

  Hosted and device authorities use the same logical operations. The device
  clauses are added by the device-adapter task; unsupported authorities fail
  closed without disclosing whether an identity exists.
  """

  alias SddOrchestrator.Accounts.{DeviceWorkspace, PersonalWorkspace}
  alias SddOrchestrator.Devices.DeviceTransaction
  alias SddOrchestrator.Specifications.SpecificationSnapshot
  alias SddOrchestrator.Specifications.SpecificationStore.{Device, Hosted}

  @type current :: %{
          specification:
            SddOrchestrator.Specifications.ProjectSpecification.t()
            | SddOrchestrator.Specifications.DeviceProjectSpecification.t(),
          revision:
            SddOrchestrator.Specifications.SpecificationRevision.t()
            | SddOrchestrator.Specifications.DeviceSpecificationRevision.t()
        }

  @spec create(PersonalWorkspace.t(), String.t(), map(), keyword()) ::
          {:ok, current()} | {:error, atom() | Ecto.Changeset.t()}
  def create(authority, project_id, attrs, opts \\ [])

  def create(%PersonalWorkspace{} = authority, project_id, attrs, opts) do
    Hosted.create(authority, project_id, attrs, opts)
  end

  def create(%DeviceWorkspace{} = authority, project_id, attrs, opts) do
    Device.create(authority, project_id, attrs, opts)
  end

  def create(_authority, _project_id, _attrs, _opts), do: {:error, :not_found}

  @spec get_current(PersonalWorkspace.t(), String.t(), String.t()) ::
          {:ok, current()} | {:error, :not_found}
  def get_current(%PersonalWorkspace{} = authority, project_id, specification_id) do
    Hosted.get_current(authority, project_id, specification_id)
  end

  def get_current(%DeviceWorkspace{} = authority, project_id, specification_id) do
    Device.get_current(authority, project_id, specification_id)
  end

  def get_current(_authority, _project_id, _specification_id), do: {:error, :not_found}

  @spec append_revision(
          PersonalWorkspace.t(),
          String.t(),
          String.t(),
          String.t(),
          map()
        ) ::
          {:ok, current()} | {:error, atom() | Ecto.Changeset.t()}
  def append_revision(
        %PersonalWorkspace{} = authority,
        project_id,
        specification_id,
        expected_revision_id,
        attrs
      ) do
    Hosted.append_revision(
      authority,
      project_id,
      specification_id,
      expected_revision_id,
      attrs
    )
  end

  def append_revision(
        %DeviceWorkspace{} = authority,
        project_id,
        specification_id,
        expected_revision_id,
        attrs
      ) do
    Device.append_revision(
      authority,
      project_id,
      specification_id,
      expected_revision_id,
      attrs
    )
  end

  @spec current_snapshot(PersonalWorkspace.t() | DeviceWorkspace.t(), String.t()) ::
          {:ok, SpecificationSnapshot.t()} | {:error, atom()}
  def current_snapshot(%PersonalWorkspace{} = authority, project_id) do
    Hosted.current_snapshot(authority, project_id)
  end

  def current_snapshot(%DeviceWorkspace{} = authority, project_id) do
    Device.current_snapshot(authority, project_id)
  end

  def current_snapshot(_authority, _project_id), do: {:error, :not_found}

  @doc """
  Adds an already-validated current specification set to a caller-owned project
  restoration transaction.

  The caller supplies its idempotency key through `opts`. Hosted callers receive
  an extended `Ecto.Multi`; device callers receive an extended worker-owned
  `DeviceTransaction`. Package parsing and project conflict policy are outside
  this boundary.
  """
  @spec prepare_restore(
          PersonalWorkspace.t() | DeviceWorkspace.t(),
          Ecto.Multi.t() | DeviceTransaction.t(),
          [map()],
          keyword()
        ) :: {:ok, Ecto.Multi.t() | DeviceTransaction.t()} | {:error, term()}
  def prepare_restore(%PersonalWorkspace{} = authority, %Ecto.Multi{} = transaction, values, opts) do
    Hosted.prepare_restore(authority, transaction, values, opts)
  end

  def prepare_restore(
        %DeviceWorkspace{} = authority,
        %DeviceTransaction{} = transaction,
        values,
        opts
      ) do
    Device.prepare_restore(authority, transaction, values, opts)
  end

  def prepare_restore(_authority, _transaction, _values, _opts),
    do: {:error, :invalid_restore}
end
