defmodule SddOrchestrator.RepositoryAssessments do
  @moduledoc """
  Owner-controlled preparation and start of exact repository assessments.

  Preparation is metadata-only and transient. It checks project authority,
  disclosure confirmation, worker workspace authorization, and reachability
  before invoking the configured worker adapter. Consumption is single-use and
  revalidates the same identity, root, and commit before the authoritative
  assessment store persists one pending request. Starting the request does not
  issue a scan command.
  """

  alias SddOrchestrator.Accounts.DeviceWorkspace
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.{Pairing, WorkerDiscovery}
  alias SddOrchestrator.Participation
  alias SddOrchestrator.Portability.HostedLocalRepositoryBinding
  alias SddOrchestrator.Projects.Project
  alias SddOrchestrator.Repo

  alias SddOrchestrator.RepositoryAssessments.{
    AssessmentStore,
    BindingStore,
    ProfileStore,
    RepositoryAssessment,
    RepositoryAssessmentCacheProvenance,
    RepositoryAssessmentCommand,
    RepositoryAssessmentResult,
    RepositoryBindingPreparation,
    RepositoryExecutionProfile,
    RepositoryExecutionProfileProposal,
    RepositoryExecutionProfileProposalEnvelope,
    RepositoryMetadataAdapter
  }

  @ttl_seconds 2 * 60

  @input_fields MapSet.new([
                  :device_workspace_id,
                  :worker_ref,
                  :selection_ref,
                  :selected_root,
                  :scanner_contract_digest,
                  :disclosure_digest,
                  :confirmed_disclosure_digest
                ])

  @type authority :: {:hosted, Ecto.UUID.t()} | {:device, DeviceWorkspace.t()}
  @type viewer :: authority() | {:participant, Ecto.UUID.t() | nil, Ecto.UUID.t()}

  @type error ::
          :unauthorized
          | :invalid_request
          | :processing_boundary_confirmation_required
          | :worker_unavailable
          | :repository_mismatch
          | :root_mismatch
          | :invalid_worker_response
          | :expired
          | :stale
          | :unknown_or_replayed
          | :already_terminal
          | :invalid_cache_provenance
          | :invalid_proposal_envelope
          | :invalid_result
          | :invalid_proposal
          | :stale_assessment
          | :not_found
          | :persistence_failed
          | :no_execution_profile

  @spec prepare_binding(authority(), String.t(), map(), keyword()) ::
          {:ok, RepositoryBindingPreparation.t()} | {:error, error()}
  def prepare_binding(authority, project_id, attrs, opts \\ []) do
    now = now(opts)
    adapter = Keyword.get(opts, :adapter, RepositoryMetadataAdapter.configured())
    store = Keyword.get(opts, :store, BindingStore)

    with {:ok, input} <- validate_input(attrs),
         {:ok, project} <- authorize_project(authority, project_id),
         :ok <- confirm_disclosure(input),
         :ok <- authorize_worker_workspace(authority, input),
         {:ok, worker} <- authorize_worker(input, now),
         {:ok, identity} <- repository_identity(project),
         request <- request(project.id, identity, worker.id, input),
         {:ok, result} <- invoke(adapter, :prepare, request),
         {:ok, prepared_fields} <- validate_result(result, request),
         {:ok, preparation} <- build_preparation(prepared_fields, request, now, opts),
         :ok <- store.put(preparation, request, adapter) do
      {:ok, preparation}
    else
      {:error, reason} when reason in [:worker_unavailable, :repository_mismatch] ->
        {:error, reason}

      {:error, reason}
      when reason in [
             :unauthorized,
             :invalid_request,
             :processing_boundary_confirmation_required,
             :root_mismatch,
             :invalid_worker_response
           ] ->
        {:error, reason}

      _failure ->
        {:error, :invalid_request}
    end
  end

  @spec consume_binding(authority(), String.t(), RepositoryBindingPreparation.t(), keyword()) ::
          {:ok, RepositoryBindingPreparation.t()} | {:error, error()}
  def consume_binding(authority, project_id, preparation, opts \\ []) do
    now = now(opts)
    store = Keyword.get(opts, :store, BindingStore)

    with :ok <- valid_for_project(preparation, project_id),
         {:ok, project} <- authorize_project(authority, project_id),
         :ok <- not_expired(preparation, now, store),
         {:ok, entry} <- store.take(preparation.nonce, fingerprint(preparation)),
         :ok <- same_preparation(entry.preparation, preparation),
         {:ok, identity} <- repository_identity(project),
         :ok <- same_identity(identity, preparation),
         :ok <- authorize_worker_workspace(authority, entry.request),
         {:ok, _worker} <- authorize_worker(entry.request, now),
         {:ok, result} <- invoke(entry.adapter, :revalidate, entry.request),
         {:ok, fields} <- validate_result(result, entry.request),
         :ok <- unchanged(fields, preparation) do
      {:ok, preparation}
    else
      {:error, :unknown_or_replayed} -> {:error, :unknown_or_replayed}
      {:error, :expired} -> {:error, :expired}
      {:error, :unauthorized} -> {:error, :unauthorized}
      _changed_or_unavailable -> {:error, :stale}
    end
  end

  @doc """
  Consumes one unchanged trusted binding and persists exactly one pending
  assessment in the project's authoritative destination.

  Binding consumption performs owner, device-workspace, project, worker,
  identity, root, commit, expiry, and replay checks before the adapter is
  allowed to write. This transition deliberately has no scanner or command
  transport dependency.
  """
  @spec start_assessment(authority(), String.t(), RepositoryBindingPreparation.t(), keyword()) ::
          {:ok, RepositoryAssessment.t()} | {:error, error()}
  def start_assessment(authority, project_id, preparation, opts \\ []) do
    assessment_store = Keyword.get(opts, :assessment_store, AssessmentStore)
    started_at = now(opts)

    with {:ok, consumed} <- consume_binding(authority, project_id, preparation, opts),
         {:ok, assessment} <- RepositoryAssessment.pending(consumed, started_at),
         {:ok, persisted} <- assessment_store.put(authority, assessment) do
      {:ok, persisted}
    else
      {:error, reason} when reason in [:unauthorized, :expired, :stale, :unknown_or_replayed] ->
        {:error, reason}

      _invalid_or_unavailable_store ->
        {:error, :persistence_failed}
    end
  end

  @doc """
  Atomically records one exact command-bound terminal assessment result.

  The pending row remains authoritative for project, repository, root, commit,
  scanner, disclosure, worker, and limit selection. The result must match the
  same strict command, and the selected authoritative adapter may move that row
  only once from `pending_scan` to a terminal state.

  A completed delivery must supply the worker's current proposal envelope as
  `:proposal_envelope`; it is rebuilt from this exact assessment and stored with
  the completion or not at all. A canceled or failed delivery must supply none,
  and a completion stored without one can never gain it later.
  """
  @spec finish_assessment(
          authority(),
          String.t(),
          RepositoryAssessmentCommand.t(),
          RepositoryAssessmentResult.t(),
          RepositoryAssessmentCacheProvenance.t() | map() | nil | keyword()
        ) :: {:ok, RepositoryAssessment.t()} | {:error, error()}
  def finish_assessment(authority, project_id, command, result, provenance_or_opts \\ [])

  def finish_assessment(authority, project_id, command, result, opts) when is_list(opts) do
    do_finish_assessment(authority, project_id, command, result, nil, opts)
  end

  def finish_assessment(authority, project_id, command, result, provenance)
      when is_map(provenance) do
    do_finish_assessment(authority, project_id, command, result, provenance, [])
  end

  def finish_assessment(authority, project_id, command, result, provenance) do
    do_finish_assessment(authority, project_id, command, result, provenance, [])
  end

  @spec finish_assessment(
          authority(),
          String.t(),
          RepositoryAssessmentCommand.t(),
          RepositoryAssessmentResult.t(),
          RepositoryAssessmentCacheProvenance.t() | map() | nil,
          keyword()
        ) :: {:ok, RepositoryAssessment.t()} | {:error, error()}
  def finish_assessment(authority, project_id, command, result, provenance, opts)
      when is_list(opts) do
    do_finish_assessment(authority, project_id, command, result, provenance, opts)
  end

  defp do_finish_assessment(authority, project_id, command, result, provenance, opts) do
    assessment_store = Keyword.get(opts, :assessment_store, AssessmentStore)
    delivered_envelope = Keyword.get(opts, :proposal_envelope)
    terminal_at = now(opts)

    with true <- is_binary(project_id),
         %RepositoryAssessmentCommand{} <- command,
         %RepositoryAssessmentResult{} <- result,
         true <- command.project_id == project_id and result.project_id == project_id,
         {:ok, pending} <- assessment_store.fetch(authority, project_id, command.assessment_id),
         {:ok, terminal} <-
           RepositoryAssessment.terminal(pending, command, result, provenance, terminal_at),
         {:ok, envelope} <- terminal_envelope(terminal, delivered_envelope, terminal_at),
         {:ok, persisted} <- assessment_store.transition(authority, pending, terminal, envelope) do
      {:ok, persisted}
    else
      false ->
        {:error, :invalid_result}

      {:error, reason}
      when reason in [
             :not_found,
             :unauthorized,
             :already_terminal,
             :invalid_cache_provenance,
             :invalid_proposal_envelope,
             :invalid_result,
             :stale
           ] ->
        {:error, reason}

      _invalid_or_unavailable_store ->
        {:error, :persistence_failed}
    end
  end

  defp terminal_envelope(%RepositoryAssessment{state: "completed"} = terminal, delivered, now) do
    RepositoryExecutionProfileProposalEnvelope.new(delivered, terminal, now)
  end

  defp terminal_envelope(%RepositoryAssessment{}, nil, _now), do: {:ok, nil}

  defp terminal_envelope(%RepositoryAssessment{}, _delivered, _now),
    do: {:error, :invalid_proposal_envelope}

  @doc """
  Reads one completed assessment with its verified authoritative envelope.

  The stored envelope is revalidated against that exact assessment, so review
  never sees a legacy, missing, corrupted, or foreign-bound value and no caller
  may supply replacement proposal fields.
  """
  @spec proposal_envelope(viewer(), String.t(), String.t(), keyword()) ::
          {:ok,
           %{
             assessment: RepositoryAssessment.t(),
             envelope: RepositoryExecutionProfileProposalEnvelope.t()
           }}
          | {:error, error()}
  def proposal_envelope(viewer, project_id, assessment_id, opts \\ []) do
    assessment_store = Keyword.get(opts, :assessment_store, AssessmentStore)

    case assessment_store.fetch_envelope(viewer, project_id, assessment_id) do
      {:ok, assessment, envelope} -> {:ok, %{assessment: assessment, envelope: envelope}}
      {:error, :invalid_proposal_envelope} -> {:error, :invalid_proposal_envelope}
      _missing -> {:error, :not_found}
    end
  end

  @doc """
  Reads the current reviewable proposal for one project.

  The newest assessment must itself be the completed one, because approval
  refuses any older assessment. Every proposal field is rebuilt from that
  assessment and its verified envelope, so this read accepts no caller-supplied
  proposal value and can never present a prior assessment's binding.
  """
  @spec profile_review(viewer(), String.t(), keyword()) ::
          {:ok,
           %{
             assessment: RepositoryAssessment.t(),
             envelope: RepositoryExecutionProfileProposalEnvelope.t(),
             proposal: RepositoryExecutionProfileProposal.t(),
             profiles: [RepositoryExecutionProfile.t()]
           }}
          | {:error, :not_found | :invalid_proposal_envelope}
  def profile_review(viewer, project_id, opts \\ []) do
    assessment_store = Keyword.get(opts, :assessment_store, AssessmentStore)
    profile_store = Keyword.get(opts, :profile_store, ProfileStore)

    with {:ok, %RepositoryAssessment{state: "completed"} = current} <-
           assessment_store.latest(viewer, project_id),
         {:ok, assessment, envelope} <-
           assessment_store.fetch_envelope(viewer, project_id, current.id),
         {:ok, proposal} <-
           RepositoryExecutionProfileProposal.new(
             assessment,
             RepositoryExecutionProfileProposalEnvelope.proposal_fields(envelope)
           ) do
      {:ok,
       %{
         assessment: assessment,
         envelope: envelope,
         proposal: proposal,
         profiles: profile_store.list(viewer, project_id)
       }}
    else
      {:error, reason} when reason in [:invalid_proposal_envelope, :invalid_proposal] ->
        {:error, :invalid_proposal_envelope}

      _unavailable ->
        {:error, :not_found}
    end
  end

  @doc """
  Reads the approved execution profile currently in force for one project.

  Approval is append-only and every version is kept, so the highest version is
  the one that governs a run started now. A project that has approved none has
  no execution contract to run against, which is a refusal rather than an
  empty profile, so nothing falls back to a generic set of commands.
  """
  @spec approved_profile(viewer(), String.t()) ::
          {:ok, RepositoryExecutionProfile.t()} | {:error, :no_execution_profile}
  def approved_profile(viewer, project_id) do
    case ProfileStore.list(viewer, project_id) do
      [] -> {:error, :no_execution_profile}
      profiles -> {:ok, Enum.max_by(profiles, & &1.version)}
    end
  end

  @doc """
  Normalizes one transient profile proposal from an exact completed assessment.

  The assessment supplies the repository binding, base revision, and existing
  repository-instruction precedence. Caller input is restricted to the managed
  runtime fields that the assessment review proposes; it cannot replace those
  assessment-owned values.
  """
  @spec propose_profile(authority(), String.t(), String.t(), map(), keyword()) ::
          {:ok, RepositoryExecutionProfileProposal.t()} | {:error, error()}
  def propose_profile(authority, project_id, assessment_id, attrs, opts \\ []) do
    assessment_store = Keyword.get(opts, :assessment_store, AssessmentStore)

    with {:ok, project} <- authorize_project(authority, project_id),
         {:ok, assessment} <-
           assessment_store.fetch(authority, project_id, assessment_id),
         :ok <- current_completed_assessment(authority, assessment_store, project, assessment),
         {:ok, proposal} <- RepositoryExecutionProfileProposal.new(assessment, attrs) do
      {:ok, proposal}
    else
      {:error, :invalid_proposal} -> {:error, :invalid_proposal}
      {:error, :stale_assessment} -> {:error, :stale_assessment}
      _unauthorized_or_missing -> {:error, :not_found}
    end
  end

  @doc "Appends one immutable profile version after an exact owner-only approval."
  @spec approve_profile(
          authority(),
          String.t(),
          RepositoryExecutionProfileProposal.t(),
          keyword()
        ) ::
          {:ok, RepositoryExecutionProfile.t()} | {:error, error()}
  def approve_profile(authority, project_id, proposal, opts \\ []) do
    decide_profile(authority, project_id, proposal, :approve, opts)
  end

  @doc "Rejects one current proposal without appending a profile version."
  @spec reject_profile(authority(), String.t(), RepositoryExecutionProfileProposal.t(), keyword()) ::
          :ok | {:error, error()}
  def reject_profile(authority, project_id, proposal, opts \\ []) do
    decide_profile(authority, project_id, proposal, :reject, opts)
  end

  @doc """
  Whether one hosted project's repository can be assessed at all.

  Assessability is reachability, not a provider connection. A project whose
  repository is a Git repository on the owner's Mac carries no GitHub-shaped
  `RepositoryConnection`, because that row needs a numeric provider repository
  id a local repository never has. It reaches its repository through the worker
  binding instead, so either link admits the project.

  The binding only has to exist. Whether that Mac answers right now is a state
  the screen renders, not an authorization question, so no availability is read
  here.

  This is the one rule. `authorize_project/2` and the assessment screen both
  read it, so the screen can never offer a project the service refuses.
  """
  @spec assessable_hosted_project?(Project.t()) :: boolean()
  def assessable_hosted_project?(
        %Project{storage_mode: "hosted", lifecycle_state: "active"} = project
      ) do
    project = Repo.preload(project, [:repository_connection, :hosted_local_repository_binding])

    match?(%{state: "connected"}, project.repository_connection) or
      match?(%HostedLocalRepositoryBinding{}, project.hosted_local_repository_binding)
  end

  def assessable_hosted_project?(_project), do: false

  defp decide_profile(authority, project_id, proposal, decision, opts)
       when decision in [:approve, :reject] do
    assessment_store = Keyword.get(opts, :assessment_store, AssessmentStore)
    profile_store = Keyword.get(opts, :profile_store, ProfileStore)
    decided_at = now(opts)

    with %RepositoryExecutionProfileProposal{} <- proposal,
         true <- RepositoryExecutionProfileProposal.valid?(proposal),
         :ok <- proposal_for_project(proposal, project_id),
         {:ok, project} <- authorize_project(authority, project_id),
         {:ok, assessment} <-
           assessment_store.fetch(authority, project_id, proposal.assessment_id),
         :ok <- current_completed_assessment(authority, assessment_store, project, assessment),
         :ok <- proposal_matches_assessment(proposal, assessment),
         {:ok, actor_ref} <- approval_actor_ref(authority) do
      case decision do
        :approve -> profile_store.append(authority, assessment, proposal, actor_ref, decided_at)
        :reject -> :ok
      end
    else
      false -> {:error, :invalid_proposal}
      {:error, reason} when reason in [:stale_assessment, :unauthorized] -> {:error, reason}
      {:error, :not_found} -> {:error, :stale_assessment}
      %{} -> {:error, :invalid_proposal}
      _invalid -> {:error, :invalid_proposal}
    end
  end

  defp current_completed_assessment(
         authority,
         assessment_store,
         project,
         %RepositoryAssessment{} = assessment
       ) do
    with true <- RepositoryAssessment.strict?(assessment),
         true <- assessment.state == "completed",
         true <- RepositoryAssessment.cache_provenance_complete?(assessment),
         {:ok, latest} <- assessment_store.latest(authority, assessment.project_id),
         true <- latest.id == assessment.id,
         {:ok, identity} <- repository_identity(project),
         true <- identity.repository_provider == assessment.repository_provider,
         true <- identity.repository_id == assessment.repository_id,
         true <- project.id == assessment.project_id do
      :ok
    else
      _stale -> {:error, :stale_assessment}
    end
  end

  defp current_completed_assessment(_authority, _store, _project, _assessment),
    do: {:error, :stale_assessment}

  defp proposal_for_project(
         %RepositoryExecutionProfileProposal{project_id: project_id},
         project_id
       ),
       do: :ok

  defp proposal_for_project(_proposal, _project_id), do: {:error, :unauthorized}

  defp proposal_matches_assessment(proposal, assessment) do
    if RepositoryExecutionProfileProposal.matches_assessment?(proposal, assessment),
      do: :ok,
      else: {:error, :stale_assessment}
  end

  defp approval_actor_ref({:hosted, account_id}), do: uuid(account_id)
  defp approval_actor_ref({:device, %DeviceWorkspace{id: workspace_id}}), do: uuid(workspace_id)

  defp validate_input(attrs) when is_map(attrs) do
    with true <- MapSet.new(Map.keys(attrs)) == @input_fields,
         {:ok, device_workspace_id} <- uuid(attrs.device_workspace_id),
         {:ok, worker_ref} <- uuid(attrs.worker_ref),
         {:ok, selection_ref} <- selection_ref(attrs.selection_ref),
         {:ok, selected_root} <- RepositoryBindingPreparation.normalize_root(attrs.selected_root),
         {:ok, scanner_digest} <-
           RepositoryBindingPreparation.digest(attrs.scanner_contract_digest),
         {:ok, disclosure_digest} <-
           RepositoryBindingPreparation.digest(attrs.disclosure_digest),
         {:ok, confirmed_digest} <-
           RepositoryBindingPreparation.digest(attrs.confirmed_disclosure_digest) do
      {:ok,
       %{
         device_workspace_id: device_workspace_id,
         worker_ref: worker_ref,
         selection_ref: selection_ref,
         selected_root: selected_root,
         scanner_contract_digest: scanner_digest,
         disclosure_digest: disclosure_digest,
         confirmed_disclosure_digest: confirmed_digest
       }}
    else
      _invalid -> {:error, :invalid_request}
    end
  end

  defp validate_input(_attrs), do: {:error, :invalid_request}

  defp confirm_disclosure(%{
         disclosure_digest: digest,
         confirmed_disclosure_digest: digest
       }),
       do: :ok

  defp confirm_disclosure(_input),
    do: {:error, :processing_boundary_confirmation_required}

  # Ownership still decides who may act, and it is still checked first. The
  # project rule that follows only decides which repositories can be reached.
  defp authorize_project({:hosted, account_id}, project_id) do
    with {:ok, project} <- Participation.owned_project(account_id, project_id),
         true <- assessable_hosted_project?(project) do
      {:ok, project}
    else
      _unauthorized -> {:error, :unauthorized}
    end
  rescue
    _error -> {:error, :unauthorized}
  end

  defp authorize_project({:device, %DeviceWorkspace{id: authority_id}}, project_id) do
    with {:ok, %DeviceWorkspace{id: ^authority_id} = current_workspace} <- Devices.get_workspace(),
         {:ok, %{status: "connected"} = project} <- Devices.get_project(project_id),
         true <- DeviceWorkspace.owns_project?(current_workspace, project) do
      {:ok, project}
    else
      _unauthorized -> {:error, :unauthorized}
    end
  rescue
    _error -> {:error, :unauthorized}
  catch
    :exit, _reason -> {:error, :unauthorized}
  end

  defp authorize_project(_authority, _project_id), do: {:error, :unauthorized}

  defp authorize_worker_workspace({:hosted, _account_id}, _input), do: :ok

  defp authorize_worker_workspace(
         {:device, %DeviceWorkspace{id: workspace_id}},
         %{device_workspace_id: workspace_id}
       ),
       do: :ok

  defp authorize_worker_workspace(_authority, _input), do: {:error, :unauthorized}

  defp authorize_worker(input, now) do
    workers = Pairing.active_workers(input.device_workspace_id)

    case Enum.find(workers, &(&1.id == input.worker_ref)) do
      nil ->
        {:error, :unauthorized}

      worker ->
        # The same reading the screen's worker list uses. `:detected` requires
        # `Devices.worker_available?/1`, the one definition of an available
        # worker, so a worker this action refuses was never offered and a worker
        # that was offered is not refused a minute later.
        if WorkerDiscovery.status([worker], now: now) == :detected,
          do: {:ok, worker},
          else: {:error, :worker_unavailable}
    end
  rescue
    _error -> {:error, :worker_unavailable}
  end

  defp repository_identity(%{
         repository_provider: provider,
         canonical_repository_id: repository_id
       }) do
    normalize_identity(provider, repository_id)
  end

  defp repository_identity(%{repository_provider: provider, repository_id: repository_id}) do
    normalize_identity(provider, repository_id)
  end

  defp repository_identity(_project), do: {:error, :unauthorized}

  defp normalize_identity(provider, repository_id) do
    with {:ok, provider} <- opaque_ref(provider),
         {:ok, repository_id} <- opaque_ref(repository_id) do
      {:ok, %{repository_provider: provider, repository_id: repository_id}}
    else
      _invalid -> {:error, :unauthorized}
    end
  end

  defp request(project_id, identity, worker_ref, input) do
    %{
      project_id: project_id,
      repository_provider: identity.repository_provider,
      repository_id: identity.repository_id,
      device_workspace_id: input.device_workspace_id,
      worker_ref: worker_ref,
      selection_ref: input.selection_ref,
      selected_root: input.selected_root,
      scanner_contract_digest: input.scanner_contract_digest,
      disclosure_digest: input.disclosure_digest
    }
  end

  defp invoke(adapter, operation, request) when operation in [:prepare, :revalidate] do
    case apply(adapter, operation, [request]) do
      {:ok, result} when is_map(result) -> {:ok, result}
      {:error, :worker_unavailable} -> {:error, :worker_unavailable}
      {:error, :repository_mismatch} -> {:error, :repository_mismatch}
      {:error, _reason} -> {:error, :invalid_worker_response}
      _invalid -> {:error, :invalid_worker_response}
    end
  rescue
    _error -> {:error, :worker_unavailable}
  catch
    _kind, _reason -> {:error, :worker_unavailable}
  end

  defp validate_result(result, request) do
    with true <-
           MapSet.new(Map.keys(result)) ==
             MapSet.new([:repository_provider, :repository_id, :root, :commit]),
         {:ok, provider} <- opaque_ref(result.repository_provider),
         {:ok, repository_id} <- opaque_ref(result.repository_id),
         true <- provider == request.repository_provider,
         true <- repository_id == request.repository_id,
         {:ok, root} <- RepositoryBindingPreparation.normalize_root(result.root),
         true <- root == request.selected_root,
         {:ok, commit} <- RepositoryBindingPreparation.full_commit(result.commit) do
      {:ok,
       %{
         repository_provider: provider,
         repository_id: repository_id,
         root: root,
         commit: commit
       }}
    else
      false ->
        if identity_mismatch?(result, request),
          do: {:error, :repository_mismatch},
          else: {:error, :root_mismatch}

      _invalid ->
        {:error, :invalid_worker_response}
    end
  end

  defp identity_mismatch?(result, request) do
    to_string(Map.get(result, :repository_provider, "")) != request.repository_provider or
      to_string(Map.get(result, :repository_id, "")) != request.repository_id
  end

  defp build_preparation(fields, request, issued_at, opts) do
    ttl = Keyword.get(opts, :ttl_seconds, @ttl_seconds)

    RepositoryBindingPreparation.new(%{
      project_id: request.project_id,
      repository_provider: fields.repository_provider,
      repository_id: fields.repository_id,
      root: fields.root,
      commit: fields.commit,
      scanner_contract_digest: request.scanner_contract_digest,
      disclosure_digest: request.disclosure_digest,
      worker_ref: request.worker_ref,
      nonce: Ecto.UUID.generate(),
      issued_at: issued_at,
      expires_at: DateTime.add(issued_at, ttl, :second)
    })
  end

  defp valid_for_project(%RepositoryBindingPreparation{} = preparation, project_id) do
    with true <- RepositoryBindingPreparation.valid?(preparation),
         {:ok, normalized_project_id} <- uuid(project_id),
         true <- preparation.project_id == normalized_project_id do
      :ok
    else
      _invalid -> {:error, :unauthorized}
    end
  end

  defp valid_for_project(_preparation, _project_id), do: {:error, :unauthorized}

  defp not_expired(preparation, now, store) do
    if RepositoryBindingPreparation.expired?(preparation, now) do
      store.discard(preparation.nonce, fingerprint(preparation))
      {:error, :expired}
    else
      :ok
    end
  end

  defp same_preparation(stored, presented) do
    if fingerprint(stored) == fingerprint(presented),
      do: :ok,
      else: {:error, :unknown_or_replayed}
  end

  defp same_identity(identity, preparation) do
    if identity.repository_provider == preparation.repository_provider and
         identity.repository_id == preparation.repository_id,
       do: :ok,
       else: {:error, :stale}
  end

  defp unchanged(fields, preparation) do
    if fields.repository_provider == preparation.repository_provider and
         fields.repository_id == preparation.repository_id and fields.root == preparation.root and
         fields.commit == preparation.commit,
       do: :ok,
       else: {:error, :stale}
  end

  defp fingerprint(preparation), do: RepositoryBindingPreparation.fingerprint(preparation)

  defp uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> :error
    end
  end

  defp uuid(_value), do: :error

  defp opaque_ref(value) when is_integer(value) and value >= 0,
    do: {:ok, Integer.to_string(value)}

  defp opaque_ref(value) when is_binary(value) do
    normalized = String.trim(value)

    if byte_size(normalized) <= 255 and
         Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._:-]*\z/, normalized),
       do: {:ok, normalized},
       else: :error
  end

  defp opaque_ref(_value), do: :error

  defp selection_ref(value) when is_binary(value) do
    normalized = String.trim(value)

    if Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\z/, normalized),
      do: {:ok, normalized},
      else: :error
  end

  defp selection_ref(_value), do: :error

  defp now(opts) do
    opts
    |> Keyword.get(:now, DateTime.utc_now())
    |> DateTime.truncate(:second)
  end
end
