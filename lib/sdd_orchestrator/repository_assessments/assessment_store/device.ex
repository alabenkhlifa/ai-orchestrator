defmodule SddOrchestrator.RepositoryAssessments.AssessmentStore.Device do
  @moduledoc "Device-local assessment-store adapter backed by the worker-owned store."

  @behaviour SddOrchestrator.RepositoryAssessments.AssessmentStore

  alias SddOrchestrator.Accounts.DeviceWorkspace
  alias SddOrchestrator.Devices

  alias SddOrchestrator.RepositoryAssessments.{
    RepositoryAssessment,
    RepositoryExecutionProfileProposalEnvelope
  }

  @impl true
  def put(
        {:device, %DeviceWorkspace{} = authority},
        %RepositoryAssessment{} = assessment
      ) do
    with true <- RepositoryAssessment.strict?(assessment),
         true <- assessment.state == RepositoryAssessment.pending_state(),
         {:ok, project} <- authorize(authority, assessment.project_id),
         true <- exact_binding?(project, assessment),
         {:ok, value} <-
           Devices.put_repository_assessment(
             assessment.project_id,
             assessment.id,
             RepositoryAssessment.to_value(assessment)
           ) do
      RepositoryAssessment.from_value(value)
    else
      false -> {:error, :unauthorized}
      {:error, :not_found} -> {:error, :unauthorized}
      {:error, reason} -> {:error, reason}
    end
  end

  def put(_authority, _assessment), do: {:error, :unsupported_authority}

  @impl true
  def transition(
        {:device, %DeviceWorkspace{} = authority},
        %RepositoryAssessment{} = pending,
        %RepositoryAssessment{} = terminal,
        envelope
      ) do
    with true <- RepositoryAssessment.strict?(pending),
         true <- RepositoryAssessment.strict?(terminal),
         {:ok, project} <- authorize(authority, pending.project_id),
         true <- exact_binding?(project, pending),
         true <- pending.state == RepositoryAssessment.pending_state(),
         true <- RepositoryAssessment.terminal_state?(terminal.state),
         true <- RepositoryAssessment.same_binding?(pending, terminal),
         {:ok, envelope_value} <- envelope_value(terminal, envelope),
         {:ok, value} <-
           Devices.transition_repository_assessment(
             pending.project_id,
             pending.id,
             RepositoryAssessment.pending_state(),
             RepositoryAssessment.to_value(terminal),
             envelope_value
           ) do
      RepositoryAssessment.from_value(value)
    else
      false -> {:error, :stale}
      {:error, :not_found} -> {:error, :unauthorized}
      {:error, reason} -> {:error, reason}
    end
  end

  def transition(_authority, _pending, _terminal, _envelope),
    do: {:error, :unsupported_authority}

  @impl true
  def fetch_envelope({:device, %DeviceWorkspace{} = authority}, project_id, assessment_id) do
    with {:ok, _project} <- authorize(authority, project_id),
         {:ok, assessment} <- fetch({:device, authority}, project_id, assessment_id),
         true <- assessment.state == "completed",
         {:ok, value} <-
           Devices.get_repository_assessment_proposal_envelope(project_id, assessment_id),
         {:ok, envelope} <- RepositoryExecutionProfileProposalEnvelope.from_value(value),
         {:ok, verified} <-
           RepositoryExecutionProfileProposalEnvelope.verify(envelope, assessment) do
      {:ok, assessment, verified}
    else
      {:error, :invalid_proposal_envelope} -> {:error, :invalid_proposal_envelope}
      _missing -> {:error, :not_found}
    end
  end

  def fetch_envelope(_viewer, _project_id, _assessment_id), do: {:error, :not_found}

  @impl true
  def fetch({:device, %DeviceWorkspace{} = authority}, project_id, assessment_id) do
    with {:ok, _project} <- authorize(authority, project_id),
         {:ok, value} <- Devices.get_repository_assessment(project_id, assessment_id),
         {:ok, assessment} <- RepositoryAssessment.from_value(value),
         true <- assessment.project_id == project_id and assessment.id == assessment_id do
      {:ok, assessment}
    else
      _missing -> {:error, :not_found}
    end
  end

  def fetch(_authority, _project_id, _assessment_id), do: {:error, :not_found}

  @impl true
  def latest({:device, %DeviceWorkspace{} = authority}, project_id) do
    with {:ok, _project} <- authorize(authority, project_id),
         {:ok, value} <- Devices.latest_repository_assessment(project_id),
         {:ok, assessment} <- RepositoryAssessment.from_value(value),
         true <- assessment.project_id == project_id do
      {:ok, assessment}
    else
      _missing -> {:error, :not_found}
    end
  end

  def latest(_authority, _project_id), do: {:error, :not_found}

  @impl true
  def count({:device, %DeviceWorkspace{} = authority}, project_id) do
    case authorize(authority, project_id) do
      {:ok, _project} -> Devices.repository_assessment_count(project_id)
      {:error, :not_found} -> 0
    end
  end

  def count(_authority, _project_id), do: 0

  defp authorize(%DeviceWorkspace{id: authority_id} = authority, project_id) do
    with {:ok, %DeviceWorkspace{id: ^authority_id}} <- Devices.get_workspace(),
         {:ok, %{status: "connected"} = project} <- Devices.get_project(project_id),
         true <- DeviceWorkspace.owns_project?(authority, project) do
      {:ok, project}
    else
      _missing -> {:error, :not_found}
    end
  end

  defp envelope_value(
         %RepositoryAssessment{state: "completed"} = terminal,
         %RepositoryExecutionProfileProposalEnvelope{} = envelope
       ) do
    with {:ok, verified} <-
           RepositoryExecutionProfileProposalEnvelope.verify(envelope, terminal) do
      {:ok, RepositoryExecutionProfileProposalEnvelope.to_value(verified)}
    end
  end

  defp envelope_value(%RepositoryAssessment{state: "completed"}, _envelope),
    do: {:error, :invalid_proposal_envelope}

  defp envelope_value(%RepositoryAssessment{}, nil), do: {:ok, nil}

  defp envelope_value(%RepositoryAssessment{}, _envelope),
    do: {:error, :invalid_proposal_envelope}

  defp exact_binding?(project, assessment) do
    project.repository_provider == assessment.repository_provider and
      project.repository_id == assessment.repository_id
  end
end
