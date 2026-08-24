defmodule SddOrchestrator.Worker.RunStateRetention do
  @moduledoc """
  Expiry of the worker-local provider-thread reference.

  `SddOrchestrator.Worker.RunState`'s `:agent_thread_ref` is the AI
  provider's own identifier for the conversation behind an attempt. It is
  never sent to or stored by the control plane: it exists only on this
  device, inside this worker's own run-state file. Nothing hosted can reach
  it, so the hosted sweep deliberately does not carry this rule — the
  worker enforces it against its own home directory instead, with no
  database, no context, and no network.

  A reference is kept while it is still useful: an attempt still in flight,
  or one finished recently enough that a `resume` or `retry` may still
  carry it forward (see `SddOrchestrator.Worker.CommandHandler`'s
  `carried_agent_thread_ref/2`). It is removed once its attempt is finished
  and the retention window has passed with no further change to the record.
  Nothing else moves: the attempt's identifiers, ordering values, branch,
  and lifecycle stay exactly as stored, and the participant-visible history
  the control plane holds is untouched.

  ## Reading the terminal transition

  A stored entry carries no timestamp of its own — the struct records
  identity, ordering, and lifecycle only — so the age of a finished attempt
  is read from the run-state file's own last-modified time. Every
  transition rewrites that file through `RunState.store/2`: acceptance in
  `SddOrchestrator.Worker.CommandHandler`, the provider-thread write and
  the terminal transition in `SddOrchestrator.Worker.AgentObserver`. For a
  settled record the file's mtime is therefore the moment of its last
  transition, which for a terminal entry is that terminal transition. That
  is a read of state already on disk rather than a new stored field, which
  every already-deployed worker would have to read back without it.

  Because both slots share one file, they share one transition time. What
  makes `:current` and `:previous` independent is the per-entry check
  below: each is expired only if that entry is itself terminal and itself
  still holds a reference.
  """

  alias SddOrchestrator.Worker.RunState

  @window 30 * 24 * 60 * 60

  @doc "The retention window, in seconds, a finished attempt's reference survives."
  @spec window() :: pos_integer()
  def window, do: @window

  @doc """
  Removes every expired provider-thread reference from this worker's own
  run state and returns how many were removed.

  `now` is taken from the caller rather than read here, so a sweep and its
  proof share one clock. `home_override` is forwarded to
  `SddOrchestrator.Worker.RunState` exactly as elsewhere in the worker:
  production callers never pass it and use the real worker home.

  A worker with no run-state file, with an unreadable or corrupt one, or
  with no reference stored at all is a successful no-op returning
  `{:ok, 0}` — a worker that has never run must not be the reason a sweep
  crashes. The file is rewritten only when something is actually removed,
  so a second run over the same state removes nothing and leaves the stored
  bytes and permissions as they were.
  """
  @spec prune(DateTime.t(), String.t() | nil) :: {:ok, non_neg_integer()}
  def prune(%DateTime{} = now, home_override \\ nil) do
    with {:ok, snapshot} <- RunState.load(home_override),
         {:ok, transitioned_at} <- last_transition(home_override),
         true <- expired?(now, transitioned_at) do
      expire(snapshot, home_override)
    else
      _not_expired_or_unreadable -> {:ok, 0}
    end
  end

  # The run-state file is derived from the same trusted `home_override`
  # `RunState.store/2` already documents this exception for — worker
  # configuration, never web input. Documented false positive.
  # sobelow_skip ["Traversal.FileModule"]
  defp last_transition(home_override) do
    case File.stat(RunState.path(home_override), time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} -> {:ok, mtime}
      {:error, reason} -> {:error, reason}
    end
  end

  defp expired?(now, transitioned_at), do: DateTime.to_unix(now) - transitioned_at >= @window

  defp expire(snapshot, home_override) do
    expired = %{
      current: expire_entry(snapshot.current),
      previous: expire_entry(snapshot.previous)
    }

    case removed(snapshot, expired) do
      0 ->
        {:ok, 0}

      count ->
        :ok = RunState.store(expired, home_override)
        {:ok, count}
    end
  end

  defp expire_entry(%RunState{agent_thread_ref: ref, lifecycle: lifecycle} = entry)
       when is_binary(ref) do
    if lifecycle in RunState.terminal_lifecycle_states(),
      do: %{entry | agent_thread_ref: nil},
      else: entry
  end

  # No reference to expire: an entry that never launched an agent, or an
  # empty slot on a worker that has accepted only one attempt.
  defp expire_entry(entry), do: entry

  defp removed(snapshot, expired) do
    Enum.count([:current, :previous], fn slot ->
      is_binary(reference(snapshot[slot])) and is_nil(reference(expired[slot]))
    end)
  end

  defp reference(%RunState{agent_thread_ref: ref}), do: ref
  defp reference(nil), do: nil
end
