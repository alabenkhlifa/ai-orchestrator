defmodule SddOrchestrator.Delivery.Reconciliation.Decision do
  @moduledoc """
  What reconciliation concluded about one attempt a worker reported.

  The conclusion is a value rather than an effect, so what the control plane
  decided can be proven without letting it change anything. Two outcomes are
  answers the worker acts on and write nothing at all; only the two that
  supersede an attempt touch authoritative state.
  """

  @type outcome :: :continue | :fence_stale_worker | :schedule_retry | :terminal

  @type t :: %__MODULE__{
          outcome: outcome(),
          reason: String.t(),
          worker_id: String.t() | nil,
          run_id: String.t() | nil,
          branch: String.t() | nil,
          workspace: String.t() | nil,
          attempt_number: pos_integer() | nil,
          fence_token: pos_integer() | nil,
          last_sequence: non_neg_integer() | nil,
          replay_from: pos_integer() | nil,
          due_at: DateTime.t() | nil,
          results: map()
        }

  defstruct [
    :outcome,
    :reason,
    :worker_id,
    :run_id,
    :branch,
    :workspace,
    :attempt_number,
    :fence_token,
    :last_sequence,
    :replay_from,
    :due_at,
    results: %{}
  ]

  @doc """
  Whether the reported worker must stop.

  A stop travels back on the reconciliation reply rather than through the
  outbox, because a superseded worker must not be able to cause a durable write
  merely by announcing itself.
  """
  @spec stop?(t()) :: boolean()
  def stop?(%__MODULE__{outcome: :fence_stale_worker}), do: true
  def stop?(%__MODULE__{}), do: false
end

defmodule SddOrchestrator.Delivery.Reconciliation do
  @moduledoc """
  Proving what is actually true after a restart, a reconnect, or a silence.

  A control plane that reboots, a channel that drops, and a worker that comes
  back all pose the same question: is the process out there still the one this
  run authorized? Process memory cannot answer it, so the answer is rows. What
  a reconnecting worker claims about its attempt, fence, lease, branch,
  workspace, and position in the event stream is compared against the
  authoritative record, and exactly one of four things follows.

  A worker that still holds the current attempt keeps going. A worker holding a
  fence the run has moved past is told to stop and changes nothing, which is the
  entire point of fencing: a superseded execution must not be able to move a run
  by talking about it. An attempt whose lease expired with nothing alive behind
  it is superseded and the next bounded retry is scheduled — the same run,
  branch, workspace, and worker, on the schedule and budget the retry path
  already owns. When that budget is gone the run stops terminally with a visible
  `Failed` status, and the feature stays in `In development` because the work
  stopped rather than went backwards.

  Two rules hold on every path. No reconciliation starts an attempt beside a
  live one: the commit that creates the next attempt is the commit that ends the
  current one. And no reconciliation moves a run to a different worker — a
  snapshot from a worker that does not hold the attempt's lease is a second
  executor, not a recovery.

  The three checks that make a worker's word trustworthy are the same ones
  `EventIngestion` applies to an event: the envelope against the protocol
  schema, the fence against the run's current attempt, and the sequence against
  what that attempt has already seen. A snapshot is not an event, so it cannot
  pass through that path, but it is answered by the same rules.
  """

  alias SddOrchestrator.Delivery.{
    CommandOutbox,
    DeliveryStore,
    ExecutionManifest,
    ProtocolCodec,
    Retry,
    RunAttempt,
    Start
  }

  alias SddOrchestrator.Delivery.Reconciliation.Decision

  @type authority :: DeliveryStore.authority()

  @type error ::
          :invalid_snapshot
          | :unsupported_authority
          | :unknown_feature
          | term()

  @snapshot_type "reconciliation_snapshot"

  # The reported states that mean a worker process is still executing. Anything
  # else has already stopped, which is what makes an expired lease recoverable
  # rather than merely late.
  @live_states ~w(blocked running)

  # Recorded on the run when nothing is left of an execution. The word is the
  # retry path's own classification, so one vocabulary describes the failure
  # wherever it was noticed.
  @lost_reason "worker_unavailable"

  @doc """
  Reconciles one worker's snapshot against authoritative state and applies it.

  Returns one decision per reported attempt, in the order the worker reported
  them. A decision that supersedes an attempt carries the records its commit
  produced; the two that change nothing carry none, because there is nothing to
  carry.
  """
  @spec reconcile(authority(), Ecto.UUID.t(), map(), keyword()) ::
          {:ok, [Decision.t()]} | {:error, error()}
  def reconcile(authority, project_id, snapshot, opts \\ []) do
    with {:ok, evaluated} <- evaluate(authority, project_id, snapshot, opts) do
      apply_decisions(evaluated, opts)
    end
  end

  @doc """
  Decides the same outcomes without applying any of them.

  Exposed so the comparison can be proven on its own, and so a caller that only
  needs to know whether a worker is still current does not have to risk a write
  to find out.
  """
  @spec decide(authority(), Ecto.UUID.t(), map(), keyword()) ::
          {:ok, [Decision.t()]} | {:error, error()}
  def decide(authority, project_id, snapshot, opts \\ []) do
    with {:ok, evaluated} <- evaluate(authority, project_id, snapshot, opts) do
      {:ok, Enum.map(evaluated, fn {decision, _context} -> decision end)}
    end
  end

  @doc """
  Returns what a control-plane restart abandoned.

  A dispatcher that died mid-delivery left claims behind, and nothing else would
  ever pick them up. Recovery is therefore a query and an update rather than a
  rebuilt in-memory queue: the instructions were always rows, and returning the
  expired claims is the whole of it.

  The queue this recovers is the control plane's own outbox. A
  device-authoritative project's commands live in the worker's own store, which
  this process never claimed and a restart here cannot strand.
  """
  @spec recover(authority(), keyword()) ::
          {:ok, %{released: non_neg_integer(), pending: non_neg_integer(), at: DateTime.t()}}
          | {:error, :unsupported_authority}
  def recover(authority, opts \\ []) do
    if DeliveryStore.supported?(authority) do
      {:ok,
       %{
         released: CommandOutbox.release_expired(opts),
         pending: CommandOutbox.pending_count(opts),
         at: now(opts)
       }}
    else
      {:error, :unsupported_authority}
    end
  end

  @doc "The reported worker states that mean a process is still executing."
  @spec live_states() :: [String.t()]
  def live_states, do: @live_states

  defp evaluate(authority, project_id, snapshot, opts) do
    with :ok <- ProtocolCodec.validate(snapshot),
         :ok <- snapshot?(snapshot),
         :ok <- supported?(authority) do
      {:ok,
       Enum.map(
         snapshot["attempts"],
         &evaluate_one(authority, project_id, snapshot["worker_id"], &1, opts)
       )}
    end
  end

  defp evaluate_one(authority, project_id, worker_id, reported, opts) do
    context = %{
      authority: authority,
      project_id: project_id,
      worker_id: worker_id,
      reported: reported,
      now: now(opts),
      run: nil,
      attempt: nil
    }

    case resolve(context) do
      {:ok, resolved} -> {classify(resolved, opts), resolved}
      {:error, reason} -> {decision(context, :fence_stale_worker, reason), context}
    end
  end

  # The run is read inside the project being reconciled, which is also the
  # workspace boundary: the worker places every run under
  # `<root>/<project_id>/<run_id>`, so a run this project does not own names a
  # workspace this control plane cannot reconcile.
  defp resolve(%{authority: authority, project_id: project_id, reported: reported} = context) do
    with {:ok, run} <- fetch_run(authority, project_id, reported["run_id"]),
         {:ok, attempt} <- current_attempt(authority, project_id, run) do
      {:ok, %{context | run: run, attempt: attempt}}
    end
  end

  # Order matters. Identity is settled before ordering, and ordering before
  # liveness, so a worker that should not be talking about this run at all is
  # never the reason authoritative state moves.
  defp classify(%{run: run, attempt: attempt, reported: reported} = context, opts) do
    cond do
      not same_worker?(attempt, context.worker_id) ->
        decision(context, :fence_stale_worker, "other_worker")

      not current_attempt?(attempt, reported) ->
        decision(context, :fence_stale_worker, "stale_fence")

      not same_branch?(run, reported) ->
        decision(context, :fence_stale_worker, "branch_mismatch")

      RunAttempt.lease_active?(attempt, context.now) ->
        continue(context)

      live_process?(reported) ->
        decision(context, :fence_stale_worker, "live_process_without_lease")

      Retry.exhausted?(run, attempt.attempt_number) ->
        decision(context, :terminal, "budget_exhausted")

      true ->
        scheduled(context, opts)
    end
  end

  # The lease, not the reported process, decides that an attempt is still the
  # run's. A worker that restarted and lost its process still holds the attempt
  # it leased, and resuming that attempt under the unchanged fence is the one
  # recovery that cannot produce a second executor.
  defp continue(%{attempt: attempt, reported: reported} = context),
    do:
      decision(context, :continue, "current_attempt", replay_from: replay_from(attempt, reported))

  defp scheduled(%{attempt: attempt} = context, opts) do
    # The wait is a due time on a durable command rather than a sleeping
    # process, so a control-plane restart during the backoff loses no retry. The
    # curve and the budget belong to the retry path; reconciliation must not
    # invent a second schedule for the same run.
    due_at = DateTime.add(context.now, Retry.backoff(attempt.attempt_number, opts), :second)

    decision(context, :schedule_retry, "lease_expired", due_at: due_at)
  end

  defp apply_decisions(evaluated, opts) do
    Enum.reduce_while(evaluated, {:ok, []}, fn {decision, context}, {:ok, applied} ->
      case apply_decision(context, decision, opts) do
        {:ok, decided} -> {:cont, {:ok, applied ++ [decided]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # A continuation and a stale fence are answers, not state changes. Writing
  # anything for them — even an activity entry — would hand a superseded worker
  # a way to leave a mark on a run it no longer executes.
  defp apply_decision(_context, %Decision{outcome: outcome} = decision, _opts)
       when outcome in [:continue, :fence_stale_worker],
       do: {:ok, decision}

  defp apply_decision(context, %Decision{outcome: :schedule_retry} = decision, opts) do
    with {:ok, manifest} <- next_manifest(context, opts),
         {:ok, results} <- commit(context, retry_steps(context, decision, manifest, opts)) do
      {:ok, %{decision | results: results}}
    end
  end

  defp apply_decision(context, %Decision{outcome: :terminal} = decision, _opts) do
    with {:ok, feature} <- fetch_feature(context),
         {:ok, results} <- commit(context, terminal_steps(context, decision, feature)) do
      {:ok, %{decision | results: results}}
    end
  end

  # Five records, five steps, each written exactly once. Ending the superseded
  # attempt is part of the commit that creates its successor, so no reconciled
  # run can hold two current attempts even for the width of a transaction.
  defp retry_steps(%{run: run, attempt: attempt} = context, decision, manifest, opts) do
    [
      {:superseded, {:transition_attempt, attempt, "superseded"}},
      {:run, {:advance_attempt_number, run, manifest.attempt_number}},
      {:attempt, {:insert_attempt, attempt_attrs(run, attempt, manifest)}},
      {:activity,
       {:append_activity,
        %{
          project_id: run.project_id,
          feature_id: run.feature_id,
          run_id: run.id,
          attempt_id: {:ref, :attempt, :id},
          actor_kind: "system",
          type: "reconciled",
          payload: %{
            "operation_key" => operation_key(context, "schedule_retry"),
            "outcome" => "schedule_retry",
            "reason" => decision.reason,
            "attempt_number" => manifest.attempt_number,
            "prior_attempt_number" => attempt.attempt_number,
            "branch" => run.branch,
            "workspace" => decision.workspace,
            "last_sequence" => attempt.last_sequence,
            "due_at" => DateTime.to_iso8601(decision.due_at)
          }
        }}},
      {:command,
       {:enqueue_command,
        %{
          id: Keyword.get(opts, :command_id, Ecto.UUID.generate()),
          project_id: run.project_id,
          run_id: run.id,
          attempt_id: {:ref, :attempt, :id},
          operation: "retry",
          expected_state_version: run.state_version,
          manifest_digest: ExecutionManifest.digest(manifest),
          due_at: decision.due_at
        }}}
    ]
  end

  # Four records, four steps, and deliberately no command: an execution nobody
  # can recover must not leave an instruction behind that would start a further
  # attempt nobody authorized.
  defp terminal_steps(%{run: run, attempt: attempt} = context, decision, feature) do
    [
      {:attempt, {:transition_attempt, attempt, "failed"}},
      {:run, {:transition_run, run, "failed", [failure_reason: @lost_reason]}},
      # A status, never a column. The work stopped where it was; it did not move
      # back to a stage a reader already saw it leave.
      {:feature, {:set_feature_status, feature, "failed"}},
      {:activity,
       {:append_activity,
        %{
          project_id: run.project_id,
          feature_id: run.feature_id,
          run_id: run.id,
          attempt_id: attempt.id,
          actor_kind: "system",
          type: "reconciled",
          payload: %{
            "operation_key" => operation_key(context, "terminal"),
            "outcome" => "terminal",
            "reason" => decision.reason,
            "failure_reason" => @lost_reason,
            "attempt_number" => attempt.attempt_number,
            "branch" => run.branch,
            "workspace" => decision.workspace,
            "last_sequence" => attempt.last_sequence
          }
        }}}
    ]
  end

  defp attempt_attrs(run, attempt, manifest) do
    %{
      run_id: run.id,
      attempt_number: manifest.attempt_number,
      continuation_reason: "automatic_retry",
      effective_revision_id: run.effective_revision_id,
      effective_revision_digest: run.effective_revision_digest,
      manifest_digest: ExecutionManifest.digest(manifest),
      fence_token: attempt.fence_token + 1
    }
  end

  # The branch, the workspace, and the configured worker come from the run and
  # the project's configuration, never from the snapshot, so a reconnecting
  # worker cannot steer its own next attempt onto different work.
  defp next_manifest(%{run: run, attempt: attempt}, opts) do
    config = Keyword.merge(Start.execution_config(), opts)

    ExecutionManifest.new(%{
      "manifest_version" => ExecutionManifest.manifest_version(),
      "project_id" => run.project_id,
      "feature_id" => run.feature_id,
      "run_id" => run.id,
      "attempt_number" => max(attempt.attempt_number, run.current_attempt_number) + 1,
      "approved_slice" => run.approved_slice,
      "starting_revision_id" => run.starting_revision_id,
      "starting_revision_digest" => run.starting_revision_digest,
      "effective_revision_id" => run.effective_revision_id,
      "effective_revision_digest" => run.effective_revision_digest,
      "repository_base_revision" => Keyword.fetch!(config, :repository_base_revision),
      "target_branch" => run.branch,
      "required_checks" => Keyword.get(config, :required_checks, []),
      "agent_ref" => Keyword.get(config, :agent_ref, %{}),
      "worker_ref" => Keyword.get(config, :worker_ref, %{}),
      "continuation" => %{
        "reason" => "automatic_retry",
        "prior_attempt_number" => attempt.attempt_number
      }
    })
  end

  defp decision(context, outcome, reason, extra \\ []) do
    %Decision{
      outcome: outcome,
      reason: reason,
      worker_id: context.worker_id,
      run_id: context.reported["run_id"],
      branch: context.run && context.run.branch,
      workspace: workspace_ref(context.project_id, context.reported["run_id"]),
      attempt_number: context.attempt && context.attempt.attempt_number,
      fence_token: context.attempt && context.attempt.fence_token,
      last_sequence: context.attempt && context.attempt.last_sequence
    }
    |> struct(extra)
  end

  # A snapshot from a worker that does not hold this attempt's lease is a second
  # executor rather than a recovery, so it is stopped and never migrated onto.
  # An attempt nobody has leased yet has no holder to displace.
  defp same_worker?(%RunAttempt{lease_owner: nil}, _worker_id), do: true
  defp same_worker?(%RunAttempt{lease_owner: owner}, worker_id), do: owner == worker_id

  # The fence is the whole point: a worker whose attempt was superseded still
  # holds the old token, and no amount of correct-looking snapshot gets past it.
  defp current_attempt?(%RunAttempt{} = attempt, reported) do
    attempt.fence_token == reported["fence_token"] and
      attempt.attempt_number == reported["attempt_number"]
  end

  defp same_branch?(run, %{"branch" => branch}), do: run.branch == branch

  defp live_process?(%{"state" => state}), do: state in @live_states

  # The worker holds events this control plane never accepted, so it is told the
  # first position still missing instead of resending a run's whole history. A
  # worker that is behind has nothing to replay: its events already landed.
  defp replay_from(%RunAttempt{last_sequence: last}, %{"last_sequence" => reported}) do
    if reported > last, do: last + 1, else: nil
  end

  # Derived, never reported. The worker places every run under
  # `<root>/<project_id>/<run_id>`, so naming the project and the run names the
  # workspace, and a reconciled attempt provably continues in the same one.
  defp workspace_ref(project_id, run_id) when is_binary(project_id) and is_binary(run_id),
    do: Path.join(project_id, run_id)

  defp workspace_ref(_project_id, _run_id), do: nil

  # The reconciled outcome is keyed by the fence it acted on, so a snapshot
  # redelivered by an at-least-once channel is recognisable in the history
  # rather than looking like a second recovery of the same attempt.
  defp operation_key(%{run: run, attempt: attempt}, outcome),
    do: "reconcile:#{outcome}:#{run.id}:#{attempt.fence_token}"

  defp snapshot?(%{"type" => @snapshot_type}), do: :ok
  defp snapshot?(_envelope), do: {:error, :invalid_snapshot}

  defp supported?(authority) do
    if DeliveryStore.supported?(authority), do: :ok, else: {:error, :unsupported_authority}
  end

  defp fetch_run(authority, project_id, run_id) do
    case DeliveryStore.fetch_run(authority, project_id, run_id) do
      {:ok, run} -> {:ok, run}
      :error -> {:error, "unknown_run"}
    end
  end

  # A run whose attempts have all ended has nothing for a worker to be current
  # with, which is exactly the reconnect that must be stopped rather than
  # resumed.
  defp current_attempt(authority, project_id, run) do
    case DeliveryStore.current_attempt(authority, project_id, run.id) do
      {:ok, attempt} -> {:ok, attempt}
      :error -> {:error, "no_current_attempt"}
    end
  end

  defp fetch_feature(%{authority: authority, project_id: project_id, run: run}) do
    case DeliveryStore.fetch_feature(authority, project_id, run.feature_id) do
      {:ok, feature} -> {:ok, feature}
      :error -> {:error, :unknown_feature}
    end
  end

  defp commit(%{authority: authority, run: run}, steps) do
    authority
    |> DeliveryStore.commit(run.project_id, steps)
    |> case do
      {:ok, results} -> {:ok, results}
      {:error, _step, reason} -> {:error, reason}
    end
  end

  defp now(opts), do: Keyword.get(opts, :now, DateTime.utc_now())
end
