defmodule SddOrchestrator.Delivery.Start do
  @moduledoc """
  Starting development on one ready feature.

  This is the moment the product commits to consequential, costly work, so
  everything it depends on is revalidated here rather than trusted from the
  screen that offered the button: current participation, current readiness
  against the revision actually in play, and a confirmation of the processing
  boundary currently in force.

  Starting is explicit and never automatic. Becoming ready does not start
  anything; a person does. What that person's press creates is one run bound to
  one immutable starting revision, one isolated branch, one first attempt bound
  to its immutable execution manifest, the activity that records it, and one
  durable start command — all in a single authoritative transaction, in either
  storage authority.
  """

  alias SddOrchestrator.Accounts.{DeviceWorkspace, PersonalWorkspace}
  alias SddOrchestrator.AIRuntime.{ModelCatalogs, PersonalConnections, RuntimeSessions}
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.LocalWorker

  alias SddOrchestrator.Delivery.{
    AgentRun,
    DeliveryStore,
    ExecutionManifest,
    LocalWorkerRunGovernance,
    ParticipantGuard,
    ProcessingDisclosure,
    Readiness,
    RunTransitions
  }

  alias SddOrchestrator.Portability.HostedLocalRepositoryBinding
  alias SddOrchestrator.Repo
  alias SddOrchestrator.RepositoryAssessments
  alias SddOrchestrator.SpecificationStore

  @type authority :: Readiness.authority()
  @type actor :: ParticipantGuard.actor()

  @type precondition_key ::
          :ready | :boundary | :execution_profile | :worker | :ai_connection

  @type precondition_route ::
          :readiness
          | :processing_boundary
          | :repository_profile
          | :project_connection
          | :ai_connections

  @typedoc "One start precondition, its state right now, and where it is resolved."
  @type precondition :: %{
          key: precondition_key(),
          met?: boolean(),
          route: precondition_route()
        }

  @type error ::
          :unauthorized
          | :not_ready
          | :boundary_unconfirmed
          | :already_started
          | :no_specification
          | :no_execution_profile
          | :invalid_manifest
          | {:ai_connection_selection_required, [Ecto.UUID.t()]}
          | term()

  # Every start precondition, in the order a person meets them, each with the
  # page that resolves it. The list is the readout's order, so a reader works
  # down it instead of hunting for the one item that stopped them.
  @precondition_routes [
    ready: :readiness,
    boundary: :processing_boundary,
    execution_profile: :repository_profile,
    worker: :project_connection,
    ai_connection: :ai_connections
  ]

  @doc """
  Starts development for the acting participant.

  Any current participant may start a ready feature — starting is a
  collaborative project action rather than an owner's privilege. Cancelling it
  later is not, which is why that authorization is narrower.
  """
  @spec start(authority(), actor(), map(), keyword()) :: {:ok, map()} | {:error, error()}
  def start(authority, actor, %{project: project, feature: feature}, opts \\ []) do
    with {:ok, member} <- ParticipantGuard.authorize_action(project.id, actor, :start_run),
         :ok <- boundary_confirmed(project.id, actor),
         :ok <- ready?(authority, project.id, actor, feature.id),
         {:ok, current} <- current_revision(authority, project.id, feature),
         :ok <- not_already_started(authority, project, feature),
         {:ok, manifest} <- manifest_for(authority, project, feature, current, opts),
         {:ok, ai_connection_id} <- resolve_ai_connection(project.id, member.account_id, opts),
         {:ok, session_id} <- pin_governed_session(manifest, ai_connection_id, member, opts),
         {:ok, results} <- commit(authority, project, feature, member, manifest, opts) do
      record_governance(manifest.run_id, session_id)
      {:ok, results}
    end
  end

  @doc """
  The ordered start preconditions for one feature, each met or unmet.

  A person who cannot start has to see why and where to go, so this answers
  every item rather than one verdict. The screen renders the list and offers
  the action only when all of it is met, and `available?/3` asks this same list
  the same question, so the readout and the check cannot disagree.

  Nothing here is stored. It describes this instant, and `start/4` revalidates
  every part of it, because the answer can change between render and press.
  """
  @spec preconditions(authority(), actor(), map()) :: [precondition()]
  def preconditions(authority, actor, %{project: project, feature: feature}) do
    met = met_preconditions(authority, actor, project, feature)

    Enum.map(@precondition_routes, fn {key, route} ->
      %{key: key, met?: Map.fetch!(met, key), route: route}
    end)
  end

  @doc """
  Reports whether the start action may be offered right now.

  Exactly `preconditions/3` with every item met, so the list a person reads and
  the answer the screen acts on are one thing.
  """
  @spec available?(authority(), actor(), map()) :: boolean()
  def available?(authority, actor, subject),
    do: authority |> preconditions(actor, subject) |> Enum.all?(& &1.met?)

  # Someone who may not start this feature is told nothing is met, rather than
  # which parts of a project they are not in are already in order.
  defp met_preconditions(authority, actor, project, feature) do
    case ParticipantGuard.authorize_action(project.id, actor, :start_run) do
      {:ok, member} ->
        checked_preconditions(authority, actor, project, feature, member)

      {:error, _unauthorized} ->
        Map.new(@precondition_routes, fn {key, _route} -> {key, false} end)
    end
  end

  # Each item is the same question `start/4` asks, asked through the same
  # helper, so an item can never report a state the press would then refuse.
  defp checked_preconditions(authority, actor, project, feature, member) do
    %{
      ready:
        feature.lifecycle_column == "ready_for_development" and
          Readiness.start_available?(authority, project.id, actor, feature.id),
      boundary: ProcessingDisclosure.confirmed?(project.id, actor),
      execution_profile: approved_profile?(authority, project.id),
      worker: worker_attached?(project.id),
      ai_connection: match?({:ok, _id}, resolve_ai_connection(project.id, member.account_id, []))
    }
  end

  defp approved_profile?(authority, project_id) do
    match?(
      {:ok, _profile},
      RepositoryAssessments.approved_profile(profile_viewer(authority), project_id)
    )
  end

  # The binding names the machine this project's work runs on, and
  # `Devices.worker_available?/1` is the one definition of whether that
  # machine's worker is attached to the control plane right now. A project with
  # no binding has no worker to be attached, so it is not met.
  defp worker_attached?(project_id) do
    case bound_local_worker(project_id) do
      nil -> false
      worker -> Devices.worker_available?(worker)
    end
  end

  defp commit(authority, project, feature, member, manifest, opts) do
    digest = ExecutionManifest.digest(manifest)
    operation_key = "start:#{manifest.run_id}"

    if RunTransitions.applied?(authority, project.id, feature.id, operation_key) do
      {:error, :already_started}
    else
      authority
      |> DeliveryStore.commit(
        project.id,
        steps(project, feature, member, manifest, digest, operation_key, opts)
      )
      |> case do
        {:ok, results} -> {:ok, results}
        {:error, _step, reason} -> {:error, reason}
      end
    end
  end

  # One transaction: the feature moves, the run and its first attempt are
  # created against the exact revision, the history records it, and the worker
  # instruction is queued. A rejection anywhere leaves none of it.
  defp steps(project, feature, member, manifest, digest, operation_key, opts) do
    [
      {:feature, {:transition_feature, feature, "in_development", []}},
      {:run,
       {:insert_run,
        %{
          id: manifest.run_id,
          project_id: project.id,
          feature_id: feature.id,
          initiator_account_id: member.account_id,
          starting_revision_id: manifest.starting_revision_id,
          starting_revision_digest: manifest.starting_revision_digest,
          approved_slice: manifest.approved_slice,
          branch: manifest.target_branch
        }}},
      {:attempt,
       {:insert_attempt,
        %{
          run_id: manifest.run_id,
          attempt_number: 1,
          continuation_reason: "initial",
          effective_revision_id: manifest.effective_revision_id,
          effective_revision_digest: manifest.effective_revision_digest,
          manifest_digest: digest,
          required_checks: manifest.required_checks,
          fence_token: 1
        }}},
      {:activity,
       {:append_activity,
        %{
          project_id: project.id,
          feature_id: feature.id,
          run_id: manifest.run_id,
          attempt_id: {:ref, :attempt, :id},
          actor_kind: "participant",
          actor_account_id: member.account_id,
          type: "run_started",
          payload: %{
            "operation_key" => operation_key,
            "branch" => manifest.target_branch,
            "revision_id" => manifest.starting_revision_id
          }
        }}},
      {:command,
       {:enqueue_command,
        %{
          id: Keyword.get(opts, :command_id, Ecto.UUID.generate()),
          project_id: project.id,
          run_id: manifest.run_id,
          attempt_id: {:ref, :attempt, :id},
          operation: "start",
          expected_state_version: 1,
          manifest_digest: digest
        }}}
    ]
  end

  # The repository's own base revision, checks, root, commands, and scope come
  # from the version of the execution profile its owner approved. Nothing here
  # falls back to configuration, so a run can only ever execute the contract a
  # person actually approved for that repository.
  defp manifest_for(authority, project, feature, current, opts) do
    run_id = Keyword.get(opts, :run_id, Ecto.UUID.generate())

    with {:ok, profile} <-
           RepositoryAssessments.approved_profile(profile_viewer(authority), project.id) do
      ExecutionManifest.new(%{
        "manifest_version" => ExecutionManifest.manifest_version(),
        "project_id" => project.id,
        "feature_id" => feature.id,
        "run_id" => run_id,
        "attempt_number" => 1,
        "approved_slice" => Keyword.get(opts, :approved_slice, "slice-07"),
        "starting_revision_id" => revision_id(current),
        "starting_revision_digest" => revision_digest(current),
        "effective_revision_id" => revision_id(current),
        "effective_revision_digest" => revision_digest(current),
        "repository_base_revision" => profile.base_revision,
        "target_branch" => branch_for(run_id, opts),
        "required_checks" => required_checks(profile),
        "repository_root" => profile.root,
        "commands" => profile.commands,
        "allowed_scope" => profile.allowed_scope,
        "agent_ref" => Keyword.get(opts, :agent_ref, %{}),
        "worker_ref" => Keyword.get(opts, :worker_ref, %{}),
        "continuation" => %{"reason" => "initial", "prior_attempt_number" => nil}
      })
    end
  end

  # The profile store answers the owner's approved versions, so the viewer is
  # built from the project's storage authority rather than from the person who
  # pressed start. Their right to press it was already checked.
  defp profile_viewer(%PersonalWorkspace{account_id: account_id}), do: {:hosted, account_id}
  defp profile_viewer(%DeviceWorkspace{} = workspace), do: {:device, workspace}

  # A profile names its required checks by the command that runs them, and
  # those names are already unique, so the manifest's named-check contract
  # carries the command as both the name and the command.
  defp required_checks(profile) do
    Enum.map(profile.required_checks, &%{"name" => &1, "command" => &1})
  end

  # One run owns one branch for its whole lifetime, so the branch name is
  # derived from the run identity rather than from the feature title, which a
  # person can change.
  defp branch_for(run_id, opts) do
    prefix = Keyword.get(opts, :branch_prefix, "sdd")

    "#{prefix}/run-#{run_id}"
  end

  defp boundary_confirmed(project_id, actor) do
    if ProcessingDisclosure.confirmed?(project_id, actor) do
      :ok
    else
      {:error, :boundary_unconfirmed}
    end
  end

  defp ready?(authority, project_id, actor, feature_id) do
    if Readiness.start_available?(authority, project_id, actor, feature_id) do
      :ok
    else
      {:error, :not_ready}
    end
  end

  # A feature already carrying a live run cannot start a second one. The
  # feature's own transition table would reject the move as well, but saying so
  # plainly is more useful than reporting an illegal transition.
  defp not_already_started(authority, project, feature) do
    authority
    |> active_run(project, feature)
    |> case do
      nil -> :ok
      _live -> {:error, :already_started}
    end
  end

  defp active_run(authority, project, feature) do
    authority
    |> DeliveryStore.list_activity(project.id, feature.id, limit: 200)
    |> Enum.filter(&(&1.type == "run_started"))
    |> Enum.map(& &1.run_id)
    |> Enum.reject(&is_nil/1)
    |> Enum.find_value(&live_run(authority, project.id, &1))
  end

  defp live_run(authority, project_id, run_id) do
    case DeliveryStore.fetch_run(authority, project_id, run_id) do
      {:ok, %AgentRun{state: state} = run} when state not in ~w(failed canceled completed) -> run
      _terminal_or_missing -> nil
    end
  end

  # Advisory only: this resolves what the initiator could pin, never what
  # authorizes it. The real, re-checked authorization happens later through
  # `PersonalConnections.resolve_working_agent_connection/2` when the session
  # is actually pinned. A project with no bound local worker (for example, a
  # device-authoritative project) has nothing to filter against, so it reports
  # zero eligible connections exactly like an unconfigured account would.
  defp resolve_ai_connection(project_id, account_id, opts) do
    case bound_local_worker(project_id) do
      nil -> {:ok, nil}
      worker -> select_eligible_connection(account_id, worker, opts)
    end
  end

  defp bound_local_worker(project_id) do
    with %HostedLocalRepositoryBinding{worker_id: worker_id} <-
           Repo.get(HostedLocalRepositoryBinding, project_id),
         %LocalWorker{} = worker <- Repo.get(LocalWorker, worker_id) do
      worker
    else
      _unbound -> nil
    end
  end

  defp select_eligible_connection(account_id, worker, opts) do
    account_id
    |> PersonalConnections.list_personal_connections()
    |> Enum.filter(&(&1.worker_id == worker.id and &1.revocation_state == "active"))
    |> Enum.map(& &1.id)
    |> choose_connection(Keyword.get(opts, :ai_runtime_connection_id))
  end

  defp choose_connection([], _requested_id), do: {:ok, nil}
  defp choose_connection([only_id], _requested_id), do: {:ok, only_id}

  defp choose_connection(eligible_ids, requested_id) do
    if requested_id != nil and requested_id in eligible_ids do
      {:ok, requested_id}
    else
      {:error, {:ai_connection_selection_required, eligible_ids}}
    end
  end

  # No connection was eligible: the run stays ungoverned, unchanged from the
  # `specs/33-local-worker-run-execution` baseline.
  defp pin_governed_session(_manifest, nil, _member, _opts), do: {:ok, nil}

  defp pin_governed_session(manifest, connection_id, member, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, model, effort} <- current_model_selection(member.account_id, connection_id, now),
         request = pin_request(manifest, connection_id, model, effort, opts),
         {:ok, session} <- RuntimeSessions.pin_session(member.account_id, request, now: now) do
      {:ok, session.session_id}
    end
  end

  # A connection was explicitly resolved, so an unavailable catalog is a pin
  # failure here, not a silent fall-through to ungoverned.
  defp current_model_selection(account_id, connection_id, now) do
    case ModelCatalogs.current_catalog(account_id, connection_id, now: now) do
      {:ok, %{models: models}} -> select_current_model(models)
      {:error, reason} -> {:error, reason}
    end
  end

  defp select_current_model(models) do
    case Enum.find(models, & &1.current) || Enum.find(models, & &1.default) do
      %{model: model, default_reasoning_effort: effort} when is_binary(effort) ->
        {:ok, model, effort}

      _no_selectable_model ->
        {:error, :unknown}
    end
  end

  # The spending ceiling is only required to pin an API-key connection;
  # `RuntimeSessions.pin_session/3` enforces that itself, so an unsupplied
  # ceiling for a connection that requires one surfaces as an ordinary pin
  # failure rather than something resolved here.
  defp pin_request(manifest, connection_id, model, effort, opts) do
    %{
      consumer: :working_agent,
      consumer_ref: "local_worker_run:" <> manifest.run_id,
      connection_id: connection_id,
      model: model,
      effort: effort,
      scarcity: :standard,
      choices: [],
      spending_ceiling: Keyword.get(opts, :ai_runtime_spending_ceiling)
    }
  end

  # Written as a plain, separate insert after `commit/6` succeeds, never
  # inside its own `steps/6` transaction: `LocalWorkerRunGovernance.run_id`
  # references the `agent_runs` row `commit/6` creates, so it can only be
  # written once that row exists. When commit fails after a successful pin,
  # the pinned session is left unlinked; `pin_session/3`'s own idempotency on
  # `consumer_ref` reconciles that on a later retry of the same run.
  defp record_governance(_run_id, nil), do: :ok

  defp record_governance(run_id, session_id) do
    LocalWorkerRunGovernance.record(run_id, session_id)
    :ok
  end

  # The feature's own linked specification, and never another of the project's.
  # Readiness judges that document, so the run has to start against the same
  # one: a project holding two specifications would otherwise have readiness
  # answer for one document and the run begin against a different one.
  defp current_revision(authority, project_id, %{specification_id: specification_id})
       when is_binary(specification_id) do
    case SpecificationStore.get_current(authority, project_id, specification_id) do
      {:ok, current} -> {:ok, current}
      _unavailable -> {:error, :no_specification}
    end
  end

  defp current_revision(_authority, _project_id, _feature), do: {:error, :no_specification}

  defp revision_id(%{revision: revision}), do: revision.id
  defp revision_digest(%{revision: revision}), do: revision.content_digest
end
