defmodule SddOrchestrator.RepositoryAssessments.AssessmentStore do
  @moduledoc """
  Equivalent persistence contract for hosted and device-authoritative assessments.

  Dispatch is determined by the already-authorized project authority. Device
  records never fall back to the hosted adapter.
  """

  alias SddOrchestrator.Accounts.DeviceWorkspace
  alias SddOrchestrator.RepositoryAssessments.AssessmentStore.{Device, Hosted}
  alias SddOrchestrator.RepositoryAssessments.RepositoryAssessment

  @type authority :: {:hosted, Ecto.UUID.t()} | {:device, DeviceWorkspace.t()}

  @callback put(authority(), RepositoryAssessment.t()) ::
              {:ok, RepositoryAssessment.t()} | {:error, atom() | Ecto.Changeset.t()}
  @callback transition(authority(), RepositoryAssessment.t(), RepositoryAssessment.t()) ::
              {:ok, RepositoryAssessment.t()} | {:error, atom() | Ecto.Changeset.t()}
  @callback fetch(authority(), Ecto.UUID.t(), Ecto.UUID.t()) ::
              {:ok, RepositoryAssessment.t()} | {:error, :not_found}
  @callback count(authority(), Ecto.UUID.t()) :: non_neg_integer()

  @spec put(authority(), RepositoryAssessment.t()) ::
          {:ok, RepositoryAssessment.t()} | {:error, atom() | Ecto.Changeset.t()}
  def put({:hosted, _account_id} = authority, assessment),
    do: Hosted.put(authority, assessment)

  def put({:device, %DeviceWorkspace{}} = authority, assessment),
    do: Device.put(authority, assessment)

  def put(_authority, _assessment), do: {:error, :unsupported_authority}

  @doc "Atomically replaces one pending assessment with its exact terminal value."
  @spec transition(authority(), RepositoryAssessment.t(), RepositoryAssessment.t()) ::
          {:ok, RepositoryAssessment.t()} | {:error, atom() | Ecto.Changeset.t()}
  def transition({:hosted, _account_id} = authority, pending, terminal),
    do: Hosted.transition(authority, pending, terminal)

  def transition({:device, %DeviceWorkspace{}} = authority, pending, terminal),
    do: Device.transition(authority, pending, terminal)

  def transition(_authority, _pending, _terminal), do: {:error, :unsupported_authority}

  @spec fetch(authority(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, RepositoryAssessment.t()} | {:error, :not_found}
  def fetch({:hosted, _account_id} = authority, project_id, assessment_id),
    do: Hosted.fetch(authority, project_id, assessment_id)

  def fetch({:device, %DeviceWorkspace{}} = authority, project_id, assessment_id),
    do: Device.fetch(authority, project_id, assessment_id)

  def fetch(_authority, _project_id, _assessment_id), do: {:error, :not_found}

  @spec count(authority(), Ecto.UUID.t()) :: non_neg_integer()
  def count({:hosted, _account_id} = authority, project_id),
    do: Hosted.count(authority, project_id)

  def count({:device, %DeviceWorkspace{}} = authority, project_id),
    do: Device.count(authority, project_id)

  def count(_authority, _project_id), do: 0
end
