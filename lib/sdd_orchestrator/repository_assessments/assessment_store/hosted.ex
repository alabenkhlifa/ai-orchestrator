defmodule SddOrchestrator.RepositoryAssessments.AssessmentStore.Hosted do
  @moduledoc "PostgreSQL assessment-store adapter for hosted projects."

  @behaviour SddOrchestrator.RepositoryAssessments.AssessmentStore

  import Ecto.Query

  alias SddOrchestrator.Participation
  alias SddOrchestrator.Portability.HostedLocalRepositoryBinding
  alias SddOrchestrator.Projects.{Project, RepositoryConnection}
  alias SddOrchestrator.Repo
  alias SddOrchestrator.RepositoryAssessments

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
  def latest(viewer, project_id) do
    with {:ok, project} <- authorize_viewer(viewer, project_id),
         %RepositoryAssessment{} = assessment <-
           RepositoryAssessment
           |> where([a], a.project_id == ^project.id)
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

  @impl true
  def latest_completed(viewer, project_id) do
    with {:ok, project} <- authorize_viewer(viewer, project_id),
         %RepositoryAssessment{} = assessment <-
           RepositoryAssessment
           |> where([a], a.project_id == ^project.id and a.state == "completed")
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

  # The row may be written only for the repository the assessment names, and only
  # while that repository is still reachable. Reachability is the assessment
  # service's own rule, read here so this store refuses exactly what the service
  # refuses.
  defp active_hosted_binding?(project, assessment) do
    project.repository_provider == assessment.repository_provider and
      project.canonical_repository_id == assessment.repository_id and
      RepositoryAssessments.assessable_hosted_project?(project)
  end

  defp transition_pending(pending, terminal) do
    pending
    |> unchanged_pending_row()
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

  # Every command-bound field must still hold its pending value, so a rebound or
  # re-planned assessment can never absorb this terminal outcome.
  defp unchanged_pending_row(pending) do
    pending_state = RepositoryAssessment.pending_state()

    RepositoryAssessment
    |> where([a], a.id == ^pending.id and a.project_id == ^pending.project_id)
    |> where([a], a.state == ^pending_state)
    |> where(
      [a],
      a.repository_provider == ^pending.repository_provider and
        a.repository_id == ^pending.repository_id
    )
    |> where([a], a.root == ^pending.root and a.commit == ^pending.commit)
    |> where(
      [a],
      a.scanner_contract_digest == ^pending.scanner_contract_digest and
        a.disclosure_digest == ^pending.disclosure_digest
    )
    |> where([a], a.worker_ref == ^pending.worker_ref)
    |> where(
      [a],
      a.scan_protocol_version == ^pending.scan_protocol_version and
        a.scan_limits == ^pending.scan_limits
    )
  end

  defp transactionally_transition(account_id, pending, terminal, envelope) do
    case Repo.transaction(fn ->
           locked_transition(account_id, pending, terminal, envelope)
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

  defp locked_transition(account_id, pending, terminal, envelope) do
    with %Project{} = project <- lock_project_binding(pending.project_id),
         {:ok, owned} <- Participation.owned_project(account_id, pending.project_id),
         true <- owned.id == project.id,
         true <- active_hosted_binding?(project, pending),
         {1, _rows} <- transition_pending(pending, terminal),
         %RepositoryAssessment{} = persisted <- Repo.get(RepositoryAssessment, pending.id),
         :ok <- insert_envelope(persisted, envelope) do
      persisted
    else
      {0, _rows} -> Repo.rollback(:stale)
      false -> Repo.rollback(:stale)
      {:error, :invalid_proposal_envelope} -> Repo.rollback(:invalid_proposal_envelope)
      _invalid -> Repo.rollback(:unauthorized)
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

  # Locks the project and the row that links it to its repository. A GitHub
  # project is linked by its connection, a project whose repository is on a Mac
  # by its worker binding, so either row admits the project and every present row
  # is held for the transition. A project with neither has no repository to hold
  # still, so it resolves to nothing at all.
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

    binding =
      HostedLocalRepositoryBinding
      |> where([b], b.project_id == ^project_id)
      |> lock("FOR UPDATE")
      |> Repo.one()

    linked_project(project, connection, binding)
  end

  defp linked_project(%Project{}, nil, nil), do: nil

  defp linked_project(%Project{} = project, connection, binding) do
    %{project | repository_connection: connection, hosted_local_repository_binding: binding}
  end

  defp linked_project(_missing_project, _connection, _binding), do: nil
end
