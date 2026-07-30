defmodule SddOrchestrator.Delivery.Retry do
  @moduledoc """
  Bounded recovery from an execution failure, on the same run.

  Not every failure deserves another attempt. A lost transport, an unavailable
  worker or provider, a rate limit, and a recoverable agent exit are the failures
  that a second attempt actually fixes. Invalid authorization, an incompatible
  protocol, an unsafe workspace, a malformed manifest, missing configuration,
  and an exhausted limit are not — retrying them burns cost and time to reach
  the same answer. A reason this module does not recognise is treated as
  terminal, because a failure nobody classified is a failure nobody proved was
  transient.

  Recovery is bounded by three automatic retries after the initial attempt, each
  scheduled further out than the last, from 15 seconds to a five-minute cap.
  Waiting is a due time on a durable command, never a sleeping process, so a
  control-plane restart during the backoff loses no retry.

  What never moves is the run, its branch, and its workspace. Only the attempt
  number and the fence token advance, which is what lets the accepted work,
  checkpoint, progress, and evidence of the failed attempt survive into the next
  one while the old worker's fence becomes useless.

  When the budget runs out, or the failure was never retryable, the run becomes
  terminally `failed` and the feature shows a visible `Failed` status. The
  feature stays in `In development`: the work did not go backwards, it stopped,
  and any current participant may start the next attempt themselves.
  """

  alias SddOrchestrator.Delivery.{
    AgentRun,
    DeliveryStore,
    EventIngestion,
    ExecutionManifest,
    ParticipantGuard,
    RunAttempt,
    Start
  }

  @type authority :: DeliveryStore.authority()
  @type actor :: ParticipantGuard.actor()
  @type classification :: :retryable | :terminal

  @type error ::
          EventIngestion.error()
          | :unauthorized
          | :unknown_feature
          | :no_failed_run
          | :no_attempt
          | :invalid_failure
          | term()

  # The event type this task owns. `EventIngestion` refuses it, which is what
  # keeps one owner per transition.
  @event_type "failed"

  # Three automatic retries after the initial attempt.
  @budget 3

  @base_seconds 15
  @cap_seconds 300

  # Jitter only ever pushes a delay later, so the first retry is never sooner
  # than the 15 seconds the design promised, and the cap still holds afterwards.
  @max_jitter 0.5

  # Doubling past this cannot produce a delay below the cap, and refusing to
  # compute it keeps a nonsense attempt number from building a huge integer.
  @max_exponent 16

  @retryable ~w(
    agent_exit_recoverable
    provider_unavailable
    rate_limited
    transport_lost
    worker_unavailable
  )

  @terminal ~w(
    incompatible_protocol
    invalid_authorization
    limits_exhausted
    malformed_manifest
    missing_configuration
    unsafe_workspace
  )

  @spec event_type() :: String.t()
  def event_type, do: @event_type

  @spec budget() :: pos_integer()
  def budget, do: @budget

  @spec retryable_reasons() :: [String.t()]
  def retryable_reasons, do: @retryable

  @spec terminal_reasons() :: [String.t()]
  def terminal_reasons, do: @terminal

  @doc """
  Classifies one failure reason as worth another attempt, or not.

  An unrecognised reason is terminal. Failing closed costs one manual retry;
  failing open spends the whole budget rediscovering that a misconfiguration is
  still a misconfiguration.
  """
  @spec classify(term()) :: classification()
  def classify(reason) when reason in @retryable, do: :retryable
  def classify(reason) when reason in @terminal, do: :terminal
  def classify(_unrecognised), do: :terminal

  @doc """
  The delay before the retry that follows attempt `retry_number`.

  Exponential from 15 seconds and capped at five minutes, with jitter so several
  runs failing on the same outage do not return in one wave. `:jitter` is
  injectable — the schedule is part of the contract and has to be provable
  without depending on a random draw.
  """
  @spec backoff(pos_integer(), keyword()) :: pos_integer()
  def backoff(retry_number, opts \\ []) when is_integer(retry_number) and retry_number > 0 do
    jitter = opts |> Keyword.get_lazy(:jitter, &random_jitter/0) |> clamp_jitter()
    exponent = min(retry_number - 1, @max_exponent)

    @base_seconds
    |> Kernel.*(Integer.pow(2, exponent))
    |> Kernel.*(1 + jitter)
    |> round()
    |> min(@cap_seconds)
  end

  @doc """
  Reports whether the automatic budget for this run is spent.

  The run's own attempt ordering is authoritative rather than the number the
  worker reported, so a worker naming an older attempt cannot buy extra retries.
  """
  @spec exhausted?(AgentRun.t(), pos_integer()) :: boolean()
  def exhausted?(%AgentRun{} = run, attempt_number) do
    max(attempt_number, run.current_attempt_number) - 1 >= @budget
  end

  @doc """
  Applies one validated `failed` worker event to the run it names.

  A retryable failure with budget left schedules the next attempt; anything else
  ends the run. Both outcomes are one authoritative transaction, and neither
  leaves the feature's column behind.
  """
  @spec handle_failure(authority(), Ecto.UUID.t(), map(), keyword()) ::
          {:ok, map()} | {:error, error()}
  def handle_failure(authority, project_id, envelope, opts \\ []) do
    with {:ok, %{run: run, attempt: attempt}} <-
           EventIngestion.accept(authority, project_id, envelope, [@event_type]),
         {:ok, reason} <- failure_reason(envelope),
         {:ok, feature} <- fetch_feature(authority, project_id, run.feature_id) do
      recover(%{
        authority: authority,
        run: run,
        attempt: attempt,
        feature: feature,
        reason: reason,
        envelope: envelope,
        opts: opts
      })
    end
  end

  @doc """
  Starts the next attempt of a failed run for the acting participant.

  Any current participant may retry. A failed run is a stopped piece of shared
  work rather than one person's, and requiring its initiator would leave a
  feature stuck behind whoever happens to be away.
  """
  @spec retry_now(authority(), actor(), map(), keyword()) :: {:ok, map()} | {:error, error()}
  def retry_now(authority, actor, %{project: project, feature: feature}, opts \\ []) do
    with {:ok, member} <- ParticipantGuard.authorize_action(project.id, actor, :retry_run),
         {:ok, run} <- failed_run(authority, project.id, feature.id),
         {:ok, attempt} <- latest_attempt(authority, project.id, run),
         {:ok, current} <- fetch_feature(authority, project.id, run.feature_id),
         {:ok, manifest} <- next_manifest(run, attempt, "manual_retry", opts) do
      commit(
        authority,
        run.project_id,
        manual_steps(run, attempt, current, member, manifest, opts)
      )
    end
  end

  @doc """
  The failed run a current participant may retry on this feature, if there is one.

  Read through the participation guard rather than a storage authority, because
  this is the screen's read and the retry action has to disappear for someone
  who may no longer act on the project.
  """
  @spec pending(authority(), actor(), map()) ::
          {:ok, AgentRun.t() | nil} | {:error, :unauthorized}
  def pending(authority, actor, %{project: project, feature: feature}) do
    with {:ok, _member} <- ParticipantGuard.authorize_action(project.id, actor, :retry_run) do
      case failed_run(authority, project.id, feature.id) do
        {:ok, run} -> {:ok, run}
        {:error, _absent} -> {:ok, nil}
      end
    end
  end

  defp recover(%{reason: reason, run: run, attempt: attempt} = context) do
    if classify(reason) == :retryable and not exhausted?(run, attempt.attempt_number) do
      schedule_retry(context)
    else
      fail_terminally(context)
    end
  end

  defp schedule_retry(%{run: run, attempt: attempt, opts: opts} = context) do
    with {:ok, manifest} <- next_manifest(run, attempt, "automatic_retry", opts) do
      # The wait is a due time the dispatcher honours, not a sleeping process, so
      # a restart during the backoff still delivers exactly one retry.
      due_at = DateTime.add(now(opts), backoff(attempt.attempt_number, opts), :second)

      commit(context.authority, run.project_id, retry_steps(context, manifest, due_at))
    end
  end

  # Five records, five steps, each written exactly once. The failed attempt and
  # the next attempt are different records, which is what lets the
  # one-current-attempt index accept the insert.
  defp retry_steps(
         %{run: run, attempt: attempt, reason: reason, envelope: envelope, opts: opts},
         manifest,
         due_at
       ) do
    digest = ExecutionManifest.digest(manifest)

    [
      {:superseded, {:transition_attempt, attempt, "failed"}},
      {:run, {:advance_attempt_number, run, manifest.attempt_number}},
      {:attempt, {:insert_attempt, attempt_attrs(run, attempt, manifest, "automatic_retry")}},
      {:activity,
       {:append_activity,
        %{
          project_id: run.project_id,
          feature_id: run.feature_id,
          run_id: run.id,
          attempt_id: {:ref, :attempt, :id},
          actor_kind: "system",
          type: "retry_scheduled",
          payload: %{
            "operation_key" => "retry:#{envelope["event_id"]}",
            "failure_reason" => reason,
            "attempt_number" => manifest.attempt_number,
            "retry_number" => attempt.attempt_number,
            "branch" => run.branch,
            "due_at" => DateTime.to_iso8601(due_at)
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
          manifest_digest: digest,
          due_at: due_at
        }}}
    ]
  end

  defp fail_terminally(%{authority: authority, run: run} = context),
    do: commit(authority, run.project_id, terminal_steps(context))

  # Four records, four steps, and deliberately no command: an exhausted or
  # non-retryable failure must not leave an instruction behind that would start
  # a fifth attempt nobody authorized.
  defp terminal_steps(%{
         run: run,
         attempt: attempt,
         feature: feature,
         reason: reason,
         envelope: envelope
       }) do
    [
      {:attempt, {:transition_attempt, attempt, "failed"}},
      {:run, {:transition_run, run, "failed", [failure_reason: reason]}},
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
          type: "run_failed",
          payload: %{
            "operation_key" => "failed:#{envelope["event_id"]}",
            "failure_reason" => reason,
            "classification" => Atom.to_string(classify(reason)),
            "attempt_number" => attempt.attempt_number,
            "branch" => run.branch,
            "budget_exhausted" => exhausted?(run, attempt.attempt_number)
          }
        }}}
    ]
  end

  # The previous attempt is already terminal after an automatic or terminal
  # failure, so superseding it is only needed when a person retries a run that
  # failed while an attempt was still live.
  defp manual_steps(run, attempt, feature, member, manifest, opts) do
    digest = ExecutionManifest.digest(manifest)

    supersede(attempt) ++
      [
        {:run,
         {:resume_run, run, run.effective_revision_id, run.effective_revision_digest,
          manifest.attempt_number}},
        {:feature, {:set_feature_status, feature, "none"}},
        {:attempt, {:insert_attempt, attempt_attrs(run, attempt, manifest, "manual_retry")}},
        {:activity,
         {:append_activity,
          %{
            project_id: run.project_id,
            feature_id: run.feature_id,
            run_id: run.id,
            attempt_id: {:ref, :attempt, :id},
            actor_kind: "participant",
            actor_account_id: member.account_id,
            type: "retry_scheduled",
            payload: %{
              "operation_key" => "manual_retry:#{run.id}:#{manifest.attempt_number}",
              "attempt_number" => manifest.attempt_number,
              "branch" => run.branch,
              "manual" => true
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
            manifest_digest: digest,
            # A person is waiting, so there is nothing transient to wait out.
            due_at: now(opts)
          }}}
      ]
  end

  defp supersede(%RunAttempt{} = attempt) do
    if RunAttempt.current?(attempt) do
      [{:superseded, {:transition_attempt, attempt, "superseded"}}]
    else
      []
    end
  end

  defp attempt_attrs(run, attempt, manifest, reason) do
    %{
      run_id: run.id,
      attempt_number: manifest.attempt_number,
      continuation_reason: reason,
      effective_revision_id: run.effective_revision_id,
      effective_revision_digest: run.effective_revision_digest,
      manifest_digest: ExecutionManifest.digest(manifest),
      required_checks: manifest.required_checks,
      fence_token: attempt.fence_token + 1
    }
  end

  # The branch and the configured worker come from the run and the project
  # configuration, never from the failure event, so a retry cannot be steered
  # onto a different branch or a different worker by whatever just failed.
  defp next_manifest(run, attempt, reason, opts) do
    config = Keyword.merge(Start.execution_config(), opts)

    ExecutionManifest.new(%{
      "manifest_version" => ExecutionManifest.manifest_version(),
      "project_id" => run.project_id,
      "feature_id" => run.feature_id,
      "run_id" => run.id,
      "attempt_number" => next_attempt_number(run, attempt),
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
        "reason" => reason,
        "prior_attempt_number" => attempt.attempt_number
      }
    })
  end

  defp next_attempt_number(run, attempt),
    do: max(attempt.attempt_number, run.current_attempt_number) + 1

  defp commit(authority, project_id, steps) do
    authority
    |> DeliveryStore.commit(project_id, steps)
    |> case do
      {:ok, results} -> {:ok, results}
      {:error, _step, reason} -> {:error, reason}
    end
  end

  # The run's own history is how a feature's runs are found, the same way the
  # start path finds a live one. A feature carries at most one failed run,
  # because a run that failed is the only thing a start would have refused.
  defp failed_run(authority, project_id, feature_id) do
    authority
    |> DeliveryStore.list_activity(project_id, feature_id, limit: 200)
    |> Enum.filter(&(&1.type == "run_started"))
    |> Enum.map(& &1.run_id)
    |> Enum.reject(&is_nil/1)
    |> Enum.reverse()
    |> Enum.find_value(&fetch_failed(authority, project_id, &1))
    |> case do
      nil -> {:error, :no_failed_run}
      run -> {:ok, run}
    end
  end

  defp fetch_failed(authority, project_id, run_id) do
    case DeliveryStore.fetch_run(authority, project_id, run_id) do
      {:ok, %AgentRun{state: "failed"} = run} -> run
      _other -> nil
    end
  end

  # A terminal attempt is no longer the current one, so the ordinary read cannot
  # find what the next attempt has to continue from.
  defp latest_attempt(authority, project_id, run) do
    case DeliveryStore.latest_attempt(authority, project_id, run.id) do
      {:ok, attempt} -> {:ok, attempt}
      :error -> {:error, :no_attempt}
    end
  end

  defp fetch_feature(authority, project_id, feature_id) do
    case DeliveryStore.fetch_feature(authority, project_id, feature_id) do
      {:ok, feature} -> {:ok, feature}
      :error -> {:error, :unknown_feature}
    end
  end

  # The reason is stored on the run and read by a person, so it has to fit the
  # run's own reason column rather than whatever length a worker sent.
  defp failure_reason(%{"payload" => %{"reason" => reason}})
       when is_binary(reason) and reason != "" do
    if byte_size(reason) <= 200, do: {:ok, reason}, else: {:error, :invalid_failure}
  end

  defp failure_reason(_envelope), do: {:error, :invalid_failure}

  defp clamp_jitter(jitter) when is_number(jitter),
    do: jitter |> max(0.0) |> min(@max_jitter) |> :erlang.float()

  defp clamp_jitter(_jitter), do: 0.0

  defp random_jitter, do: :rand.uniform() * @max_jitter

  defp now(opts), do: Keyword.get(opts, :now, DateTime.utc_now())
end
