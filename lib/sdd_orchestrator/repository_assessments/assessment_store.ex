defmodule SddOrchestrator.RepositoryAssessments.AssessmentStore do
  @moduledoc """
  Equivalent persistence contract for hosted and device-authoritative assessments.

  Dispatch is determined by the already-authorized project authority. Device
  records never fall back to the hosted adapter.
  """

  alias SddOrchestrator.Accounts.DeviceWorkspace
  alias SddOrchestrator.RepositoryAssessments.AssessmentStore.{Device, Hosted}

  alias SddOrchestrator.RepositoryAssessments.{
    RepositoryAssessment,
    RepositoryExecutionProfileProposalEnvelope
  }

  @type authority :: {:hosted, Ecto.UUID.t()} | {:device, DeviceWorkspace.t()}
  @type viewer :: authority() | {:participant, Ecto.UUID.t() | nil, Ecto.UUID.t()}

  @callback put(authority(), RepositoryAssessment.t()) ::
              {:ok, RepositoryAssessment.t()} | {:error, atom() | Ecto.Changeset.t()}
  @callback transition(
              authority(),
              RepositoryAssessment.t(),
              RepositoryAssessment.t(),
              RepositoryExecutionProfileProposalEnvelope.t() | nil
            ) ::
              {:ok, RepositoryAssessment.t()} | {:error, atom() | Ecto.Changeset.t()}
  @callback fetch(authority(), Ecto.UUID.t(), Ecto.UUID.t()) ::
              {:ok, RepositoryAssessment.t()} | {:error, :not_found}
  @callback fetch_envelope(viewer(), Ecto.UUID.t(), Ecto.UUID.t()) ::
              {:ok, RepositoryAssessment.t(), RepositoryExecutionProfileProposalEnvelope.t()}
              | {:error, :not_found | :invalid_proposal_envelope}
  @callback latest(viewer(), Ecto.UUID.t()) ::
              {:ok, RepositoryAssessment.t()} | {:error, :not_found}
  @callback latest_completed(viewer(), Ecto.UUID.t()) ::
              {:ok, RepositoryAssessment.t()} | {:error, :not_found}
  @callback count(authority(), Ecto.UUID.t()) :: non_neg_integer()

  @spec put(authority(), RepositoryAssessment.t()) ::
          {:ok, RepositoryAssessment.t()} | {:error, atom() | Ecto.Changeset.t()}
  def put({:hosted, _account_id} = authority, assessment),
    do: Hosted.put(authority, assessment)

  def put({:device, %DeviceWorkspace{}} = authority, assessment),
    do: Device.put(authority, assessment)

  def put(_authority, _assessment), do: {:error, :unsupported_authority}

  @doc """
  Atomically replaces one pending assessment with its exact terminal value.

  A completed transition must carry the exact minimized proposal envelope of
  the same delivery, and the adapter persists both or neither. An unsuccessful
  transition must carry none.
  """
  @spec transition(
          authority(),
          RepositoryAssessment.t(),
          RepositoryAssessment.t(),
          RepositoryExecutionProfileProposalEnvelope.t() | nil
        ) ::
          {:ok, RepositoryAssessment.t()} | {:error, atom() | Ecto.Changeset.t()}
  def transition(authority, pending, terminal, envelope \\ nil)

  def transition({:hosted, _account_id} = authority, pending, terminal, envelope),
    do: Hosted.transition(authority, pending, terminal, envelope)

  def transition({:device, %DeviceWorkspace{}} = authority, pending, terminal, envelope),
    do: Device.transition(authority, pending, terminal, envelope)

  def transition(_authority, _pending, _terminal, _envelope),
    do: {:error, :unsupported_authority}

  @spec fetch(authority(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, RepositoryAssessment.t()} | {:error, :not_found}
  def fetch({:hosted, _account_id} = authority, project_id, assessment_id),
    do: Hosted.fetch(authority, project_id, assessment_id)

  def fetch({:device, %DeviceWorkspace{}} = authority, project_id, assessment_id),
    do: Device.fetch(authority, project_id, assessment_id)

  def fetch(_authority, _project_id, _assessment_id), do: {:error, :not_found}

  @doc """
  Reads one completed assessment together with its verified proposal envelope.

  The stored envelope is revalidated against that assessment before it is
  returned, so a legacy, missing, corrupted, or foreign-bound value is never
  presented for review. Hosted participants read within their project role.
  """
  @spec fetch_envelope(viewer(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, RepositoryAssessment.t(), RepositoryExecutionProfileProposalEnvelope.t()}
          | {:error, :not_found | :invalid_proposal_envelope}
  def fetch_envelope({:hosted, _account_id} = viewer, project_id, assessment_id),
    do: Hosted.fetch_envelope(viewer, project_id, assessment_id)

  def fetch_envelope(
        {:participant, _account_id, _identity_id} = viewer,
        project_id,
        assessment_id
      ),
      do: Hosted.fetch_envelope(viewer, project_id, assessment_id)

  def fetch_envelope({:device, %DeviceWorkspace{}} = viewer, project_id, assessment_id),
    do: Device.fetch_envelope(viewer, project_id, assessment_id)

  def fetch_envelope(_viewer, _project_id, _assessment_id), do: {:error, :not_found}

  @doc """
  Returns the newest authoritative assessment regardless of outcome.

  Hosted participants read within their project role, so review can resolve the
  current assessment without holding the owner's authority.
  """
  @spec latest(viewer(), Ecto.UUID.t()) ::
          {:ok, RepositoryAssessment.t()} | {:error, :not_found}
  def latest({:hosted, _account_id} = viewer, project_id),
    do: Hosted.latest(viewer, project_id)

  def latest({:participant, _account_id, _identity_id} = viewer, project_id),
    do: Hosted.latest(viewer, project_id)

  def latest({:device, %DeviceWorkspace{}} = viewer, project_id),
    do: Device.latest(viewer, project_id)

  def latest(_viewer, _project_id), do: {:error, :not_found}

  @doc """
  Returns the newest assessment whose state is `"completed"`, regardless of
  whether a newer pending or failed assessment now sits on top of it.

  An approved execution profile is bound to the completed assessment it was
  approved from, and a later restart can leave a newer pending or failed
  assessment ahead of it. Reading it back requires skipping those non-terminal
  or unsuccessful attempts rather than the plain newest row `latest/2` reads.
  Hosted participants read within their project role.
  """
  @spec latest_completed(viewer(), Ecto.UUID.t()) ::
          {:ok, RepositoryAssessment.t()} | {:error, :not_found}
  def latest_completed({:hosted, _account_id} = viewer, project_id),
    do: Hosted.latest_completed(viewer, project_id)

  def latest_completed({:participant, _account_id, _identity_id} = viewer, project_id),
    do: Hosted.latest_completed(viewer, project_id)

  def latest_completed({:device, %DeviceWorkspace{}} = viewer, project_id),
    do: Device.latest_completed(viewer, project_id)

  def latest_completed(_viewer, _project_id), do: {:error, :not_found}

  @spec count(authority(), Ecto.UUID.t()) :: non_neg_integer()
  def count({:hosted, _account_id} = authority, project_id),
    do: Hosted.count(authority, project_id)

  def count({:device, %DeviceWorkspace{}} = authority, project_id),
    do: Device.count(authority, project_id)

  def count(_authority, _project_id), do: 0
end
