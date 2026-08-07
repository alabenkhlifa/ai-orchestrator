defmodule SddOrchestrator.Worker.AgentObserver do
  @moduledoc """
  Launches and polls one attempt's coding agent, and persists what the worker
  must remember between polls.

  Follows the same shape `SddOrchestrator.Worker.ExecutionPreparer` already
  established: a plain module with no process of its own, composing
  already-proven primitives and read-modify-writing
  `SddOrchestrator.Worker.RunState` around them. `SddOrchestrator.Worker.GatewayConnection`
  owns the process and the schedule; this module owns what happens on each
  tick.

  `poll/3` reloads `RunState` fresh on every call rather than trusting
  anything the caller remembered from an earlier tick, because a newer
  command may have superseded this attempt between ticks (recorded by
  `SddOrchestrator.Worker.CommandHandler` into `RunState.previous`, per its
  own progress-log note that "a later task's process/lock code reads this
  same record" — this is that later task). When the envelope this observer
  was started for no longer matches `RunState.current`, `poll/3` answers
  `{:ok, %{current?: false, observation: ...}}` without calling the agent
  adapter at all, and the empty `observation` is a placeholder shape only —
  the caller must stop rather than act on it.

  A clean agent completion (the adapter reports `{:error, :agent_exited}`
  with nothing left to drain and no terminal event ever seen) is distinct
  from both a normal observation and a supersession, so `poll/3` surfaces it
  as `{:error, :agent_exited}` rather than folding it into `{:ok, ...}` —
  the caller must be able to tell "nothing more is ever coming, but nothing
  terminal happened either" apart from every other outcome. Any other
  adapter error (e.g. `:agent_unavailable`) is returned unchanged as
  `{:error, reason}`.
  """

  alias SddOrchestrator.Delivery.AgentAdapter
  alias SddOrchestrator.Delivery.AgentAdapter.Launch
  alias SddOrchestrator.Delivery.ProtocolCodec
  alias SddOrchestrator.Delivery.Worker.ProcessLock
  alias SddOrchestrator.Delivery.Worker.Workspace
  alias SddOrchestrator.Worker.RunState

  @doc """
  Launches the agent for an accepted command envelope.

  Resolves the manifest and proven working directory the same way
  `ExecutionPreparer` does, offers the attempt's currently recorded
  `agent_thread_ref` (absent for a fresh start — a `nil` thread reference is
  correct there, not an error) to `AgentAdapter.launch/3`, and on success
  persists the launch's own `thread_ref` into `RunState.current` before
  returning — a resumed or newly started thread is recorded either way, so a
  later poll or a future resume reads the attempt's real provider context
  rather than stale or absent state.
  """
  @spec start(map(), String.t() | nil) :: {:ok, Launch.t()} | {:error, term()}
  def start(envelope, home_override \\ nil) do
    with {:ok, manifest} <- ProtocolCodec.manifest(envelope),
         {:ok, directory} <- Workspace.working_directory(manifest),
         {:ok, %{current: current}} <- RunState.load(home_override),
         {:ok, launch} <-
           AgentAdapter.launch(manifest, directory, thread_ref: thread_ref(current)) do
      case persist_thread_ref(launch.thread_ref, home_override) do
        :ok -> {:ok, launch}
        {:error, _reason} = error -> error
      end
    end
  end

  @doc """
  Observes whatever the launched agent has produced since the last call.

  Reloads `RunState` fresh and refuses to observe on behalf of an attempt
  `RunState.current` no longer names (see the moduledoc). When it still
  matches, calls `AgentAdapter.observe/2` with the durable `last_sequence`
  as the starting point, so a worker restart or a superseded-then-restored
  poll never renumbers or re-delivers a sequence already recorded.
  """
  @spec poll(map(), Launch.t(), String.t() | nil) ::
          {:ok, %{observation: AgentAdapter.observation(), current?: boolean()}}
          | {:error, :agent_exited}
          | {:error, term()}
  def poll(envelope, %Launch{} = launch, home_override \\ nil) do
    case RunState.load(home_override) do
      {:ok, %{current: current}} ->
        if current?(current, envelope) do
          observe(launch, current, envelope)
        else
          {:ok, %{observation: superseded_observation(current), current?: false}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Durably advances `RunState.current.last_sequence` after a delivered event
  is acknowledged by the control plane.

  Called once per acknowledged event, never before the acknowledgement
  arrives — the whole point is that `last_sequence` only ever reflects what
  the control plane has actually accepted, so a reconnect resumes
  observation from there instead of re-delivering. A no-longer-current
  attempt (superseded between the poll and this call) is left untouched
  rather than treated as an error: the newer attempt's own state already
  started from its own baseline.
  """
  @spec record_sequence(map(), non_neg_integer(), String.t() | nil) :: :ok | {:error, term()}
  def record_sequence(envelope, sequence, home_override \\ nil) do
    update_current(envelope, home_override, fn current ->
      %{current | last_sequence: sequence}
    end)
  end

  @doc """
  Releases the attempt's process lock and records its terminal lifecycle.

  Called exactly once, only when the agent's own observation reports a
  `"blocked"` or `"failed"` terminal event — never for a clean successful
  completion, which leaves the lock held and `RunState.current.lifecycle`
  as `"accepted"` for `specs/33-local-worker-run-execution` Task 9 (the
  required-check runner) to continue using the same locked workspace.
  """
  @spec finish(map(), String.t(), String.t() | nil) :: :ok | {:error, term()}
  def finish(envelope, terminal, home_override \\ nil) when terminal in ~w(blocked failed) do
    with {:ok, manifest} <- ProtocolCodec.manifest(envelope),
         {:ok, lock} <- ProcessLock.acquire(manifest, envelope["fence_token"]),
         :ok <- ProcessLock.release(lock) do
      update_current(envelope, home_override, fn current -> %{current | lifecycle: terminal} end)
    end
  end

  defp thread_ref(%RunState{agent_thread_ref: ref}), do: ref
  defp thread_ref(nil), do: nil

  defp persist_thread_ref(thread_ref, home_override) do
    case RunState.load(home_override) do
      {:ok, %{current: %RunState{} = current} = snapshot} ->
        updated = %{snapshot | current: %{current | agent_thread_ref: thread_ref}}
        RunState.store(updated, home_override)

      {:ok, %{current: nil}} ->
        {:error, :local_run_state_unavailable}

      {:error, _reason} ->
        {:error, :local_run_state_unavailable}
    end
  end

  defp observe(launch, current, envelope) do
    module = AgentAdapter.adapter()

    case AgentAdapter.observe(launch,
           adapter: module,
           command_id: envelope["command_id"],
           fence_token: envelope["fence_token"],
           last_sequence: current.last_sequence
         ) do
      {:ok, observation} -> {:ok, %{observation: observation, current?: true}}
      {:error, _reason} = error -> error
    end
  end

  defp current?(nil, _envelope), do: false

  defp current?(%RunState{} = current, envelope) do
    current.run_id == envelope["run_id"] and
      current.attempt_number == envelope["attempt_number"] and
      current.fence_token == envelope["fence_token"]
  end

  defp superseded_observation(current) do
    %{events: [], dropped: [], last_sequence: last_sequence(current), terminal: nil}
  end

  defp last_sequence(%RunState{last_sequence: last_sequence}), do: last_sequence
  defp last_sequence(nil), do: 0

  # A no-longer-current attempt is left untouched rather than refused: the
  # attempt that superseded it already owns `RunState.current` and this
  # caller's own next `poll/3` will see `current?: false` and stop.
  defp update_current(envelope, home_override, update) do
    case RunState.load(home_override) do
      {:ok, %{current: %RunState{} = current} = snapshot} ->
        if current?(current, envelope) do
          updated = %{snapshot | current: update.(current)}
          RunState.store(updated, home_override)
        else
          :ok
        end

      {:ok, %{current: nil}} ->
        {:error, :local_run_state_unavailable}

      {:error, _reason} ->
        {:error, :local_run_state_unavailable}
    end
  end
end
