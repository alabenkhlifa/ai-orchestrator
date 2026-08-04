defmodule SddOrchestrator.RepositoryAssessments.AssessmentStore.Hosted do
  @moduledoc "PostgreSQL assessment-store adapter for hosted projects."

  @behaviour SddOrchestrator.RepositoryAssessments.AssessmentStore

  import Ecto.Query

  alias SddOrchestrator.Participation
  alias SddOrchestrator.Projects.{Project, RepositoryConnection}
  alias SddOrchestrator.Repo

  alias SddOrchestrator.RepositoryAssessments.{
    RepositoryAssessment,
    RepositoryExecutionProfileProposalEnvelope
  }

  @impl true
  def put({:hosted, account_id}, %RepositoryAssessment{} = assessment) do
    with true <- RepositoryAssessment.strict?(assessment),
         true <- assessment.state == RepositoryAssessment.pending_state(),
         {:ok, project} <- Participation.owned_project(account_id, assessment.project_id),
         project <- Repo.preload(project, :repository_connection),
         true <- active_hosted_binding?(project, assessment) do
      Repo.insert(assessment)
    else
      _invalid -> {:error, :unauthorized}
    end
  rescue
    Ecto.Query.CastError -> {:error, :unauthorized}
  end

  def put(_authority, _assessment), do: {:error, :unsupported_authority}

  @impl true
  def transition(
        {:hosted, account_id},
        %RepositoryAssessment{} = pending,
        %RepositoryAssessment{} = terminal,
        envelope
      ) do
    with true <- RepositoryAssessment.strict?(pending),
         true <- RepositoryAssessment.strict?(terminal),
         true <- pending.state == RepositoryAssessment.pending_state(),
         true <- RepositoryAssessment.terminal_state?(terminal.state),
         true <- RepositoryAssessment.same_binding?(pending, terminal),
         :ok <- envelope_matches_outcome(terminal, envelope) do
      transactionally_transition(account_id, pending, terminal, envelope)
    else
      false -> {:error, :stale}
      {:error, reason} -> {:error, reason}
    end
  rescue
    Ecto.Query.CastError -> {:error, :unauthorized}
  end

  def transition(_authority, _pending, _terminal, _envelope),
    do: {:error, :unsupported_authority}

  @impl true
  def fetch_envelope(viewer, project_id, assessment_id) do
    with {:ok, project} <- authorize_viewer(viewer, project_id),
         %RepositoryAssessment{state: "completed"} = assessment <-
           Repo.one(
             from(a in RepositoryAssessment,
               where: a.project_id == ^project.id and a.id == ^assessment_id
             )
           ),
         %RepositoryExecutionProfileProposalEnvelope{} = envelope <-
           Repo.one(
             from(e in RepositoryExecutionProfileProposalEnvelope,
               where: e.project_id == ^project.id and e.assessment_id == ^assessment_id
             )
           ),
         {:ok, verified} <-
           RepositoryExecutionProfileProposalEnvelope.verify(envelope, assessment) do
      {:ok, assessment, verified}
    else
      {:error, :invalid_proposal_envelope} -> {:error, :invalid_proposal_envelope}
      _missing -> {:error, :not_found}
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_found}
  end

  @impl true
  def fetch({:hosted, account_id}, project_id, assessment_id) do
    with {:ok, project} <- Participation.owned_project(account_id, project_id),
         true <- project.storage_mode == "hosted" and project.lifecycle_state == "active",
         %RepositoryAssessment{} = assessment <-
           RepositoryAssessment
           |> where([a], a.project_id == ^project_id and a.id == ^assessment_id)
           |> Repo.one() do
      {:ok, assessment}
    else
      _missing -> {:error, :not_found}
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_found}
  end

  def fetch(_authority, _project_id, _assessment_id), do: {:error, :not_found}

  @impl true
  def latest({:hosted, account_id}, project_id) do
    with {:ok, project} <- Participation.owned_project(account_id, project_id),
         true <- project.storage_mode == "hosted" and project.lifecycle_state == "active",
         %RepositoryAssessment{} = assessment <-
           RepositoryAssessment
           |> where([a], a.project_id == ^project_id)
           |> order_by([a], desc: a.inserted_at, desc: a.id)
           |> limit(1)
           |> Repo.one() do
      {:ok, assessment}
    else
      _missing -> {:error, :not_found}
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_found}
  end

  def latest(_authority, _project_id), do: {:error, :not_found}

  @impl true
  def count({:hosted, account_id}, project_id) do
    with {:ok, project} <- Participation.owned_project(account_id, project_id),
         true <- project.storage_mode == "hosted" and project.lifecycle_state == "active" do
      RepositoryAssessment
      |> where([a], a.project_id == ^project_id)
      |> Repo.aggregate(:count)
    else
      _missing -> 0
    end
  rescue
    Ecto.Query.CastError -> 0
  end

  def count(_authority, _project_id), do: 0

  defp active_hosted_binding?(project, assessment) do
    project.storage_mode == "hosted" and project.lifecycle_state == "active" and
      project.repository_provider == assessment.repository_provider and
      project.canonical_repository_id == assessment.repository_id and
      match?(%{state: "connected"}, project.repository_connection)
  end

  defp transition_pending(pending, terminal) do
    pending_state = RepositoryAssessment.pending_state()

    RepositoryAssessment
    |> where(
      [a],
      a.id == ^pending.id and a.project_id == ^pending.project_id and
        a.state == ^pending_state and
        a.repository_provider == ^pending.repository_provider and
        a.repository_id == ^pending.repository_id and a.root == ^pending.root and
        a.commit == ^pending.commit and
        a.scanner_contract_digest == ^pending.scanner_contract_digest and
        a.disclosure_digest == ^pending.disclosure_digest and
        a.worker_ref == ^pending.worker_ref and
        a.scan_protocol_version == ^pending.scan_protocol_version and
        a.scan_limits == ^pending.scan_limits
    )
    |> Repo.update_all(
      set: [
        state: terminal.state,
        scan_protocol_version: terminal.scan_protocol_version,
        scan_limits: terminal.scan_limits,
        findings: terminal.findings,
        structure: terminal.structure,
        stats: terminal.stats,
        failure_code: terminal.failure_code,
        terminal_at: terminal.terminal_at,
        cache_source: terminal.cache_source,
        cache_key_sha256: terminal.cache_key_sha256,
        evidence_sha256: terminal.evidence_sha256,
        cache_stored: terminal.cache_stored,
        updated_at: terminal.updated_at
      ]
    )
  end

  defp transactionally_transition(account_id, pending, terminal, envelope) do
    case Repo.transaction(fn ->
           with %Project{} = project <- lock_project_binding(pending.project_id),
                {:ok, owned} <- Participation.owned_project(account_id, pending.project_id),
                true <- owned.id == project.id,
                true <- active_hosted_binding?(project, pending),
                {1, _rows} <- transition_pending(pending, terminal),
                %RepositoryAssessment{} = persisted <-
                  Repo.get(RepositoryAssessment, pending.id),
                :ok <- insert_envelope(persisted, envelope) do
             persisted
           else
             {0, _rows} -> Repo.rollback(:stale)
             false -> Repo.rollback(:stale)
             {:error, :invalid_proposal_envelope} -> Repo.rollback(:invalid_proposal_envelope)
             _invalid -> Repo.rollback(:unauthorized)
           end
         end) do
      {:ok, %RepositoryAssessment{} = persisted} ->
        {:ok, persisted}

      {:error, reason}
      when reason in [:stale, :unauthorized, :invalid_proposal_envelope] ->
        {:error, reason}

      {:error, _reason} ->
        {:error, :stale}
    end
  end

  defp envelope_matches_outcome(
         %RepositoryAssessment{state: "completed"},
         %RepositoryExecutionProfileProposalEnvelope{}
       ),
       do: :ok

  defp envelope_matches_outcome(%RepositoryAssessment{state: "completed"}, _envelope),
    do: {:error, :invalid_proposal_envelope}

  defp envelope_matches_outcome(%RepositoryAssessment{}, nil), do: :ok

  defp envelope_matches_outcome(%RepositoryAssessment{}, _envelope),
    do: {:error, :invalid_proposal_envelope}

  defp insert_envelope(_persisted, nil), do: :ok

  defp insert_envelope(
         %RepositoryAssessment{} = persisted,
         %RepositoryExecutionProfileProposalEnvelope{} = envelope
       ) do
    with {:ok, verified} <-
           RepositoryExecutionProfileProposalEnvelope.verify(envelope, persisted),
         {:ok, _stored} <-
           verified
           |> RepositoryExecutionProfileProposalEnvelope.create_changeset()
           |> Repo.insert() do
      :ok
    else
      _invalid -> {:error, :invalid_proposal_envelope}
    end
  end

  defp insert_envelope(_persisted, _envelope), do: {:error, :invalid_proposal_envelope}

  defp authorize_viewer({:hosted, account_id}, project_id) do
    with {:ok, project} <- Participation.owned_project(account_id, project_id),
         true <- project.storage_mode == "hosted" and project.lifecycle_state == "active" do
      {:ok, project}
    else
      _unauthorized -> {:error, :not_found}
    end
  end

  defp authorize_viewer({:participant, account_id, hosted_identity_id}, project_id) do
    with {:ok, project, role} <-
           Participation.visible_project(project_id, account_id, hosted_identity_id),
         true <- role in [:owner, :participant],
         true <- project.storage_mode == "hosted" and project.lifecycle_state == "active" do
      {:ok, project}
    else
      _unauthorized -> {:error, :not_found}
    end
  end

  defp authorize_viewer(_viewer, _project_id), do: {:error, :not_found}

  defp lock_project_binding(project_id) do
    project =
      Project
      |> where([p], p.id == ^project_id)
      |> lock("FOR UPDATE")
      |> Repo.one()

    connection =
      RepositoryConnection
      |> where([c], c.project_id == ^project_id)
      |> lock("FOR UPDATE")
      |> Repo.one()

    case {project, connection} do
      {%Project{} = project, %RepositoryConnection{} = connection} ->
        %{project | repository_connection: connection}

      _missing ->
        nil
    end
  end
end
