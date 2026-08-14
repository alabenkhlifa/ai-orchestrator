defmodule SddOrchestrator.ProjectAssistant.ProgressiveDiscoveryPlanner do
  @moduledoc """
  Turns a bounded budget plus the current exploration state into the next
  bounded tree operation to request, so a large repository is answered by
  progressively expanding only what a question needs rather than requesting
  everything at once (AC-13).

  This is a pure decision function, not a scheduler or a stateful process:
  callers thread the returned `exploration()` value through repeated calls to
  `next/2`, calling `SddOrchestrator.ProjectAssistant.RepositoryDiscoverer.tree/4`
  for the path each `next/2` call names and feeding the result back through
  `record/4` before asking again. The planner never calls the adapter itself
  and holds no process state of its own.

  The strategy is breadth-first from the repository root: list one directory,
  add every directory entry it reveals to the frontier, and keep listing
  until the configured call or entry budget is exhausted or the frontier runs
  empty. A budget-exhausted halt with a non-empty frontier is the bounded,
  progressive result AC-13 requires for a large repository — proof that
  discovery stopped short of walking the whole tree rather than silently
  requesting everything.
  """

  @enforce_keys [:max_calls, :max_entries]
  defstruct @enforce_keys

  @type budget :: %__MODULE__{max_calls: pos_integer(), max_entries: pos_integer()}

  @type exploration :: %{
          calls_made: non_neg_integer(),
          entries_seen: non_neg_integer(),
          frontier: [String.t()],
          visited: MapSet.t(String.t())
        }

  @type step :: {:list, String.t()} | :halt_budget_exhausted | :halt_complete

  @doc "Builds one discovery budget. Both limits must be positive."
  @spec new(pos_integer(), pos_integer()) :: budget()
  def new(max_calls, max_entries)
      when is_integer(max_calls) and max_calls > 0 and
             is_integer(max_entries) and max_entries > 0 do
    %__MODULE__{max_calls: max_calls, max_entries: max_entries}
  end

  @doc "The starting exploration state: an empty frontier seeded with the repository root."
  @spec start(String.t()) :: exploration()
  def start(root \\ ".") do
    %{calls_made: 0, entries_seen: 0, frontier: [root], visited: MapSet.new()}
  end

  @doc """
  Decides the next bounded operation.

  Returns `{:list, path}` for the next directory to list, `:halt_budget_exhausted`
  once the call or entry budget is used up (frontier may still be non-empty —
  that is the proof discovery stayed bounded), or `:halt_complete` once the
  frontier is empty and every reachable directory within budget has been
  listed.
  """
  @spec next(budget(), exploration()) :: step()
  def next(%__MODULE__{} = budget, %{} = exploration) do
    cond do
      exploration.calls_made >= budget.max_calls -> :halt_budget_exhausted
      exploration.entries_seen >= budget.max_entries -> :halt_budget_exhausted
      exploration.frontier == [] -> :halt_complete
      true -> {:list, hd(exploration.frontier)}
    end
  end

  @doc """
  Folds one `tree/1` result for `listed_path` back into the exploration
  state: marks `listed_path` visited, removes it from the frontier, adds
  every newly discovered directory to the frontier (skipping anything
  already visited or already pending), and accounts for the entries seen.
  """
  @spec record(exploration(), String.t(), [String.t()], non_neg_integer()) :: exploration()
  def record(exploration, listed_path, discovered_directories, entries_count) do
    remaining_frontier = List.delete(exploration.frontier, listed_path)
    visited = MapSet.put(exploration.visited, listed_path)

    new_directories =
      discovered_directories
      |> Enum.reject(&(MapSet.member?(visited, &1) or &1 in remaining_frontier))
      |> Enum.uniq()

    %{
      exploration
      | calls_made: exploration.calls_made + 1,
        entries_seen: exploration.entries_seen + entries_count,
        frontier: remaining_frontier ++ new_directories,
        visited: visited
    }
  end
end
