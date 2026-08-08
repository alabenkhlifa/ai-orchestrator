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

  alias SddOrchestrator.AIRuntime.PersonalConnections
  alias SddOrchestrator.Devices.LocalWorker

  alias SddOrchestrator.Delivery.{
    AgentRun,
    DeliveryStore,
    ExecutionManifest,
    ParticipantGuard,
    ProcessingDisclosure,
    Readiness,
    RunTransitions
  }

  alias SddOrchestrator.Portability.HostedLocalRepositoryBinding
  alias SddOrchestrator.Repo
  alias SddOrchestrator.SpecificationStore

  @type authority :: Readiness.authority()
  @type actor :: ParticipantGuard.actor()

  @type error ::
          :unauthorized
          | :not_ready
          | :boundary_unconfirmed
          | :already_started
          | :no_specification
          | :invalid_manifest
          | {:ai_connection_selection_required, [Ecto.UUID.t()]}
          | term()

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
         {:ok, current} <- current_revision(authority, project.id),
         :ok <- not_already_started(authority, project, feature),
         {:ok, _ai_connection_id} <- resolve_ai_connection(project.id, member.account_id, opts),
         {:ok, manifest} <- manifest_for(project, feature, current, opts) do
      commit(authority, project, feature, member, manifest, opts)
    end
  end

  @doc """
  Reports whether the start action may be offered right now.

  The screen uses this to decide whether to show the button at all; `start/4`
  revalidates every part of it, because the answer can change between render
  and press.
  """
  @spec available?(authority(), actor(), map()) :: boolean()
  def available?(authority, actor, %{project: project, feature: feature}) do
    feature.lifecycle_column == "ready_for_development" and
      Readiness.start_available?(authority, project.id, actor, feature.id) and
      ProcessingDisclosure.confirmed?(project.id, actor)
  end

  @doc "The configured execution references bound into every manifest."
  @spec execution_config() :: keyword()
  def execution_config, do: Application.get_env(:sdd_orchestrator, :delivery_execution, [])

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

  defp manifest_for(project, feature, current, opts) do
    config = Keyword.merge(execution_config(), opts)
    run_id = Keyword.get(opts, :run_id, Ecto.UUID.generate())

    ExecutionManifest.new(%{
      "manifest_version" => ExecutionManifest.manifest_version(),
      "project_id" => project.id,
      "feature_id" => feature.id,
      "run_id" => run_id,
      "attempt_number" => 1,
      "approved_slice" => Keyword.get(config, :approved_slice, "slice-07"),
      "starting_revision_id" => revision_id(current),
      "starting_revision_digest" => revision_digest(current),
      "effective_revision_id" => revision_id(current),
      "effective_revision_digest" => revision_digest(current),
      "repository_base_revision" => Keyword.fetch!(config, :repository_base_revision),
      "target_branch" => branch_for(run_id, config),
      "required_checks" => Keyword.get(config, :required_checks, []),
      "agent_ref" => Keyword.get(config, :agent_ref, %{}),
      "worker_ref" => Keyword.get(config, :worker_ref, %{}),
      "continuation" => %{"reason" => "initial", "prior_attempt_number" => nil}
    })
  end

  # One run owns one branch for its whole lifetime, so the branch name is
  # derived from the run identity rather than from the feature title, which a
  # person can change.
  defp branch_for(run_id, config) do
    prefix = Keyword.get(config, :branch_prefix, "sdd")

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

  defp current_revision(authority, project_id) do
    with {:ok, %{specifications: [entry | _rest]}} <-
           SpecificationStore.current_snapshot(authority, project_id),
         {:ok, current} <- SpecificationStore.get_current(authority, project_id, entry.id) do
      {:ok, current}
    else
      _unavailable -> {:error, :no_specification}
    end
  end

  defp revision_id(%{revision: revision}), do: revision.id
  defp revision_digest(%{revision: revision}), do: revision.content_digest
end
