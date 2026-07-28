defmodule SddOrchestrator.SpecificationStore do
  @moduledoc """
  Shared authoritative specification-store interface.

  Hosted and device authorities use the same logical operations. The device
  clauses are added by the device-adapter task; unsupported authorities fail
  closed without disclosing whether an identity exists.
  """

  alias SddOrchestrator.Accounts.{DeviceWorkspace, PersonalWorkspace}
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
end
