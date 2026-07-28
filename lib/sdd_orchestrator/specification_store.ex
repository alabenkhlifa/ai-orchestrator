defmodule SddOrchestrator.SpecificationStore do
  @moduledoc """
  Shared authoritative specification-store interface.

  Hosted and device authorities use the same logical operations. The device
  clauses are added by the device-adapter task; unsupported authorities fail
  closed without disclosing whether an identity exists.
  """

  alias SddOrchestrator.Accounts.{DeviceWorkspace, PersonalWorkspace}
  alias SddOrchestrator.Devices.DeviceTransaction

  alias SddOrchestrator.Specifications.{
    SpecificationSecurityLog,
    SpecificationSnapshot
  }

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
    authority
    |> Hosted.create(project_id, attrs, opts)
    |> SpecificationSecurityLog.audit(:create)
  end

  def create(%DeviceWorkspace{} = authority, project_id, attrs, opts) do
    authority
    |> Device.create(project_id, attrs, opts)
    |> SpecificationSecurityLog.audit(:create)
  end

  def create(_authority, _project_id, _attrs, _opts) do
    SpecificationSecurityLog.audit({:error, :not_found}, :create)
  end

  @spec get_current(PersonalWorkspace.t(), String.t(), String.t()) ::
          {:ok, current()} | {:error, :not_found}
  def get_current(%PersonalWorkspace{} = authority, project_id, specification_id) do
    authority
    |> Hosted.get_current(project_id, specification_id)
    |> SpecificationSecurityLog.audit(:get_current)
  end

  def get_current(%DeviceWorkspace{} = authority, project_id, specification_id) do
    authority
    |> Device.get_current(project_id, specification_id)
    |> SpecificationSecurityLog.audit(:get_current)
  end

  def get_current(_authority, _project_id, _specification_id) do
    SpecificationSecurityLog.audit({:error, :not_found}, :get_current)
  end

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
    authority
    |> Hosted.append_revision(project_id, specification_id, expected_revision_id, attrs)
    |> SpecificationSecurityLog.audit(:append_revision)
  end

  def append_revision(
        %DeviceWorkspace{} = authority,
        project_id,
        specification_id,
        expected_revision_id,
        attrs
      ) do
    authority
    |> Device.append_revision(project_id, specification_id, expected_revision_id, attrs)
    |> SpecificationSecurityLog.audit(:append_revision)
  end

  def append_revision(_authority, _project_id, _specification_id, _expected_revision_id, _attrs) do
    SpecificationSecurityLog.audit({:error, :not_found}, :append_revision)
  end

  @spec current_snapshot(PersonalWorkspace.t() | DeviceWorkspace.t(), String.t()) ::
          {:ok, SpecificationSnapshot.t()} | {:error, atom()}
  def current_snapshot(%PersonalWorkspace{} = authority, project_id) do
    authority
    |> Hosted.current_snapshot(project_id)
    |> SpecificationSecurityLog.audit(:current_snapshot)
  end

  def current_snapshot(%DeviceWorkspace{} = authority, project_id) do
    authority
    |> Device.current_snapshot(project_id)
    |> SpecificationSecurityLog.audit(:current_snapshot)
  end

  def current_snapshot(_authority, _project_id) do
    SpecificationSecurityLog.audit({:error, :not_found}, :current_snapshot)
  end

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
    authority
    |> Hosted.prepare_restore(transaction, values, opts)
    |> SpecificationSecurityLog.audit(:prepare_restore)
  end

  def prepare_restore(
        %DeviceWorkspace{} = authority,
        %DeviceTransaction{} = transaction,
        values,
        opts
      ) do
    authority
    |> Device.prepare_restore(transaction, values, opts)
    |> SpecificationSecurityLog.audit(:prepare_restore)
  end

  def prepare_restore(_authority, _transaction, _values, _opts) do
    SpecificationSecurityLog.audit({:error, :invalid_restore}, :prepare_restore)
  end
end
