defmodule SddOrchestrator.Delivery.EventIngestion do
  @moduledoc """
  The only way a worker event becomes durable project state.

  Everything a worker says arrives here first and is proved before it can
  change anything: the envelope against the protocol schema, the fence token
  against the run's current attempt, and the sequence against what that attempt
  has already seen. A superseded worker that never noticed it was replaced can
  therefore keep talking without being able to move the run.

  What survives is a normalized activity entry, never the provider's own event.
  Raw streams are not persisted at all — the codec rejects an envelope carrying
  credential-shaped content, and the activity payload is a minimized projection
  of the approved fields rather than a copy of whatever arrived.
  """

  alias SddOrchestrator.Delivery.{
    AgentRun,
    DeliveryStore,
    ProtocolCodec,
    RunAttempt,
    RunStatus
  }

  @type authority :: DeliveryStore.authority()

  @type error ::
          :invalid_event
          | :unknown_run
          | :no_current_attempt
          | :stale_fence
          | :stale_sequence
          | :duplicate_event
          | :unsupported_event
          | term()

  # The event types this task converts into activity. Blocked, failed,
  # evidence, and verification outcomes are owned by their own tasks and are
  # rejected here rather than half-applied.
  @handled ~w(progress workspace_ready)

  @spec handled_event_types() :: [String.t()]
  def handled_event_types, do: @handled

  @doc """
  Applies one normalized worker event to the run it names.

  Rejects rather than partially applies: an event that fails any check leaves
  the run, its attempt, and its history exactly as they were.
  """
  @spec ingest(authority(), Ecto.UUID.t(), map()) :: {:ok, map()} | {:error, error()}
  def ingest(authority, project_id, envelope) do
    with {:ok, %{run: run, attempt: attempt}} <- accept(authority, project_id, envelope, @handled) do
      apply_event(authority, project_id, run, attempt, envelope)
    end
  end

  @doc """
  Proves one event belongs to the current attempt of the run it names.

  Each event type is owned by a different task, but the three checks that make
  a worker's word trustworthy are the same for all of them, so they live here
  once instead of being restated per owner. `handled` is the caller's own event
  vocabulary; anything else is refused rather than half-applied.
  """
  @spec accept(authority(), Ecto.UUID.t(), map(), [String.t()]) ::
          {:ok, %{run: AgentRun.t(), attempt: RunAttempt.t()}} | {:error, error()}
  def accept(authority, project_id, envelope, handled) do
    with :ok <- ProtocolCodec.validate(envelope),
         :ok <- handled?(envelope, handled),
         {:ok, run} <- fetch_run(authority, project_id, envelope),
         {:ok, attempt} <- current_attempt(authority, project_id, run),
         :ok <- current_fence?(attempt, envelope),
         :ok <- sequence_advances?(attempt, envelope) do
      {:ok, %{run: run, attempt: attempt}}
    end
  end

  @doc """
  Reports whether an event would be accepted, without applying it.

  Used by the reconciliation path to decide what a reconnecting worker still
  needs to replay.
  """
  @spec acceptable?(authority(), Ecto.UUID.t(), map()) :: boolean()
  def acceptable?(authority, project_id, envelope),
    do: match?({:ok, _accepted}, accept(authority, project_id, envelope, @handled))

  defp apply_event(authority, project_id, run, attempt, envelope) do
    authority
    |> DeliveryStore.commit(project_id, steps(run, attempt, envelope))
    |> case do
      {:ok, results} -> {:ok, results}
      {:error, _step, reason} -> {:error, reason}
    end
  end

  defp steps(run, attempt, envelope) do
    [
      {:attempt, {:observe_sequence, attempt, envelope["sequence"]}},
      {:activity,
       {:append_activity,
        %{
          project_id: run.project_id,
          feature_id: run.feature_id,
          run_id: run.id,
          attempt_id: attempt.id,
          actor_kind: "agent",
          type: "progress",
          payload: payload(envelope)
        }}}
    ] ++ run_step(run)
  end

  # A pending run becomes running on its first accepted event, which is what
  # makes `In development` mean "something is actually happening". The attempt's
  # own dispatched-to-running move belongs to the acknowledgement path: one
  # commit writes each record once, so a second write cannot see a version its
  # sibling step just bumped.
  defp run_step(%AgentRun{state: "pending"} = run),
    do: [{:run, {:transition_run, run, "running", []}}]

  defp run_step(_run), do: []

  # A minimized projection of the approved fields. The provider's own event
  # shape never reaches storage, so a later protocol change cannot rewrite what
  # a participant already read.
  defp payload(envelope) do
    %{
      "operation_key" => envelope["event_id"],
      "event_type" => envelope["event_type"],
      "source" => envelope["source"],
      "sequence" => envelope["sequence"],
      "attempt_number" => envelope["attempt_number"]
    }
    |> put_summary(envelope)
  end

  defp put_summary(payload, %{"payload" => %{"summary" => summary}}) when is_binary(summary),
    do: Map.put(payload, "summary", String.slice(summary, 0, 200))

  defp put_summary(payload, _envelope), do: payload

  defp handled?(%{"event_type" => type}, handled) do
    if type in handled, do: :ok, else: {:error, :unsupported_event}
  end

  defp handled?(_envelope, _handled), do: {:error, :unsupported_event}

  defp fetch_run(authority, project_id, %{"run_id" => run_id}) do
    case DeliveryStore.fetch_run(authority, project_id, run_id) do
      {:ok, run} -> {:ok, run}
      :error -> {:error, :unknown_run}
    end
  end

  defp current_attempt(authority, project_id, run) do
    case DeliveryStore.current_attempt(authority, project_id, run.id) do
      {:ok, attempt} -> {:ok, attempt}
      :error -> {:error, :no_current_attempt}
    end
  end

  # The fence is the whole point: a worker whose attempt was superseded still
  # holds the old token, and no amount of correct-looking payload gets past it.
  defp current_fence?(%RunAttempt{fence_token: fence}, %{"fence_token" => fence}), do: :ok
  defp current_fence?(_attempt, _envelope), do: {:error, :stale_fence}

  defp sequence_advances?(%RunAttempt{last_sequence: last}, %{"sequence" => sequence}) do
    cond do
      sequence == last -> {:error, :duplicate_event}
      sequence < last -> {:error, :stale_sequence}
      true -> :ok
    end
  end

  @doc "The status a feature should show for one run, if any."
  @spec visible_status(AgentRun.t()) :: String.t()
  def visible_status(run), do: RunStatus.for_run(run)
end
