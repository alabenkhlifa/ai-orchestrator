defmodule SddOrchestrator.ProjectAssistant.RepositoryDiscoverer do
  @moduledoc """
  Bounded progressive source discovery and worker-local indexing (AC-13,
  AC-18): the tree, text-search, and line-read operations Task 4's
  `RepositoryObserver` deliberately left out of scope, plus the
  `RepositorySourceIndex` invalidation those operations key on.

  Every public function here repeats `RepositoryObserver`'s own
  authorization and worker-availability composition — acting-participant
  source authorization first (`RepositorySourceAuthorization`, reused
  unmodified), then worker reachability
  (`RepositoryWorkerAvailability`, reused unmodified) — before ever calling
  the configured `RepositoryObservationAdapter`. Nothing here caches an
  authorization or availability result across calls, matching every other
  project-assistant surface and this specification's "project and
  source-authority scoping" owned surface: a denied or unreachable outcome
  never reaches the adapter (proven with the same poison-adapter technique
  Task 4's own tests use).

  Every bounded operation additionally, and independently of whatever the
  adapter itself returns:

    * merges the caller's own exclusions with
      `RepositoryExclusions.configured/0` before the request is built, and
      filters the adapter's raw result again against the same exclusions —
      a configured sensitive or generated path is never surfaced even if a
      real worker's own exclusion enforcement is imperfect;
    * enforces its own result-count and byte budget on top of whatever the
      adapter returns, truncating and reporting `truncated: true` rather
      than trusting an unbounded payload.

  `classify/2` reuses `SddOrchestrator.RepositoryInitialization.Eligibility`'s
  exact `:empty_directory | :unborn_repository | :mature_repository`
  vocabulary rather than inventing a parallel one. It cannot call
  `Eligibility.classify/1` itself — that function inspects a local
  filesystem `Path.t()`, and nothing on this side of the worker boundary
  ever receives one — so this reuses only the vocabulary, derived from the
  same `RepositoryObservation` and root `tree/1` result every source
  question already has on hand: no branch and no commit with an empty root
  listing is indistinguishable from `Eligibility`'s "no `.git` at all, empty
  directory" case; a branch with no commit is its "`.git` exists, zero
  commits" unborn case; anything else is mature. AC-13 wants exactly this —
  absence reported directly, not as an error — regardless of which of the
  two empty cases produced it.
  """

  alias SddOrchestrator.ProjectAssistant.ProgressiveDiscoveryPlanner
  alias SddOrchestrator.ProjectAssistant.RepositoryExclusions
  alias SddOrchestrator.ProjectAssistant.RepositoryObservation
  alias SddOrchestrator.ProjectAssistant.RepositoryObservationAdapter
  alias SddOrchestrator.ProjectAssistant.RepositorySourceAuthorization
  alias SddOrchestrator.ProjectAssistant.RepositoryWorkerAvailability
  alias SddOrchestrator.RepositoryInitialization.Eligibility

  @type authority :: RepositorySourceAuthorization.authority()
  @type actor :: RepositorySourceAuthorization.actor()

  @default_tree_entry_limit 200
  @default_search_result_limit 50
  @default_tree_byte_limit 20_000
  @default_search_byte_limit 20_000
  @default_line_byte_limit 8_000
  @default_discovery_call_limit 25

  @doc """
  Lists one bounded directory (defaults to the repository root).

  `opts`:

    * `:adapter` — defaults to `RepositoryObservationAdapter.configured/0`.
    * `:worker_available` — defaults to `RepositoryWorkerAvailability.available?/2`.
    * `:path` — defaults to `"."` (repository root).
    * `:exclusions` — extra caller exclusions merged with the configured set.
    * `:max_entries`, `:max_bytes` — override the default bounds.
  """
  @spec tree(authority(), String.t(), actor(), keyword()) ::
          {:ok, %{entries: [map()], truncated: boolean()}}
          | {:error, :unauthorized | :source_denied | :worker_unavailable | atom()}
  def tree(authority, project_id, actor, opts \\ []) do
    path = Keyword.get(opts, :path, ".")
    exclusions = merged_exclusions(opts)
    max_entries = Keyword.get(opts, :max_entries, @default_tree_entry_limit)
    max_bytes = Keyword.get(opts, :max_bytes, @default_tree_byte_limit)

    with {:ok, target, adapter} <- authorize(authority, project_id, actor, opts) do
      request = %{
        project_id: target.project_id,
        repository_provider: target.repository_provider,
        repository_ref: target.repository_ref,
        path: path,
        exclusions: exclusions,
        max_entries: max_entries,
        max_bytes: max_bytes
      }

      case adapter.tree(request) do
        {:ok, raw} -> {:ok, normalize_tree(raw, exclusions, max_entries, max_bytes)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Runs one bounded text search.

  `opts` accepts the same keys as `tree/4`, plus `:max_results` and
  `:max_bytes` overrides scoped to search matches.
  """
  @spec search(authority(), String.t(), actor(), String.t(), keyword()) ::
          {:ok, %{matches: [map()], truncated: boolean()}}
          | {:error, :unauthorized | :source_denied | :worker_unavailable | atom()}
  def search(authority, project_id, actor, query, opts \\ []) do
    exclusions = merged_exclusions(opts)
    max_results = Keyword.get(opts, :max_results, @default_search_result_limit)
    max_bytes = Keyword.get(opts, :max_bytes, @default_search_byte_limit)

    with {:ok, target, adapter} <- authorize(authority, project_id, actor, opts) do
      request = %{
        project_id: target.project_id,
        repository_provider: target.repository_provider,
        repository_ref: target.repository_ref,
        query: query,
        exclusions: exclusions,
        max_results: max_results,
        max_bytes: max_bytes
      }

      case adapter.search(request) do
        {:ok, raw} -> {:ok, normalize_search(raw, exclusions, max_results, max_bytes)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Reads one bounded line range from one file.

  A path matching the configured exclusions is denied before the adapter is
  ever called (design.md: "Sensitive paths are denied before reads").
  """
  @spec lines(authority(), String.t(), actor(), String.t(), Range.t(), keyword()) ::
          {:ok, map()}
          | {:error, :unauthorized | :source_denied | :worker_unavailable | :path_denied | atom()}
  def lines(authority, project_id, actor, path, start_line..end_line//_, opts \\ []) do
    exclusions = merged_exclusions(opts)
    max_bytes = Keyword.get(opts, :max_bytes, @default_line_byte_limit)

    with :ok <- deny_if_excluded(path, exclusions),
         {:ok, target, adapter} <- authorize(authority, project_id, actor, opts) do
      request = %{
        project_id: target.project_id,
        repository_provider: target.repository_provider,
        repository_ref: target.repository_ref,
        path: path,
        start_line: start_line,
        end_line: end_line,
        max_bytes: max_bytes
      }

      case adapter.lines(request) do
        {:ok, raw} -> {:ok, normalize_lines(raw, max_bytes)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Classifies repository state using `Eligibility`'s exact vocabulary from an
  already-fetched `RepositoryObservation` and root `tree/1` result (AC-13).
  """
  @spec classify(RepositoryObservation.t(), %{entries: [map()]}) ::
          Eligibility.ok() | :mature_repository
  def classify(%RepositoryObservation{branch: nil, commit: nil}, %{entries: []}),
    do: :empty_directory

  def classify(%RepositoryObservation{commit: nil}, _tree), do: :unborn_repository
  def classify(%RepositoryObservation{}, _tree), do: :mature_repository

  @doc """
  Progressively lists the repository within a call/entry budget, using
  `ProgressiveDiscoveryPlanner` to decide each next directory rather than
  requesting the whole tree at once.

  Returns the set of listed entries gathered so far and whether the budget
  was exhausted before the frontier emptied — the bounded, non-full-upload
  result a large repository produces.
  """
  @spec discover(authority(), String.t(), actor(), keyword()) ::
          {:ok, %{entries: [map()], halted: :budget_exhausted | :complete}}
          | {:error, :unauthorized | :source_denied | :worker_unavailable | atom()}
  def discover(authority, project_id, actor, opts \\ []) do
    max_calls = Keyword.get(opts, :max_calls, @default_discovery_call_limit)
    max_entries = Keyword.get(opts, :max_entries, @default_tree_entry_limit)
    budget = ProgressiveDiscoveryPlanner.new(max_calls, max_entries)
    exploration = ProgressiveDiscoveryPlanner.start()

    walk(authority, project_id, actor, opts, budget, exploration, [])
  end

  defp walk(authority, project_id, actor, opts, budget, exploration, acc) do
    case ProgressiveDiscoveryPlanner.next(budget, exploration) do
      :halt_budget_exhausted ->
        {:ok, %{entries: acc, halted: :budget_exhausted}}

      :halt_complete ->
        {:ok, %{entries: acc, halted: :complete}}

      {:list, path} ->
        case tree(authority, project_id, actor, Keyword.put(opts, :path, path)) do
          {:ok, %{entries: entries}} ->
            directories = entries |> Enum.filter(&(&1.type == :dir)) |> Enum.map(& &1.path)

            exploration =
              ProgressiveDiscoveryPlanner.record(exploration, path, directories, length(entries))

            walk(authority, project_id, actor, opts, budget, exploration, acc ++ entries)

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp authorize(authority, project_id, actor, opts) do
    adapter = Keyword.get(opts, :adapter, RepositoryObservationAdapter.configured())

    worker_available =
      Keyword.get(opts, :worker_available, &RepositoryWorkerAvailability.available?/2)

    with {:ok, target} <- RepositorySourceAuthorization.authorize(authority, project_id, actor),
         true <- worker_available.(authority, project_id) do
      {:ok, target, adapter}
    else
      false -> {:error, :worker_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp merged_exclusions(opts) do
    caller = Keyword.get(opts, :exclusions, [])
    Enum.uniq(caller ++ RepositoryExclusions.configured())
  end

  defp deny_if_excluded(path, exclusions) do
    if RepositoryExclusions.denied?(path, exclusions),
      do: {:error, :path_denied},
      else: :ok
  end

  defp normalize_tree(raw, exclusions, max_entries, max_bytes) do
    entries = raw |> Map.get(:entries, []) |> reject_denied_entries(exclusions)

    {kept, truncated} = bound(entries, &byte_size(&1.path), max_entries, max_bytes)

    %{entries: kept, truncated: truncated or Map.get(raw, :truncated, false)}
  end

  defp normalize_search(raw, exclusions, max_results, max_bytes) do
    matches = raw |> Map.get(:matches, []) |> reject_denied_entries(exclusions)

    {kept, truncated} = bound(matches, &byte_size(&1.excerpt), max_results, max_bytes)

    %{matches: kept, truncated: truncated or Map.get(raw, :truncated, false)}
  end

  defp reject_denied_entries(entries, exclusions) do
    Enum.reject(entries, &RepositoryExclusions.denied?(&1.path, exclusions))
  end

  defp normalize_lines(raw, max_bytes) do
    content = Map.get(raw, :content, "")

    if byte_size(content) > max_bytes do
      raw
      |> Map.put(:content, binary_part(content, 0, max_bytes))
      |> Map.put(:truncated, true)
    else
      Map.put_new(raw, :truncated, false)
    end
  end

  defp bound(items, byte_fun, max_count, max_bytes) do
    {reversed_kept, _count, _bytes, truncated} =
      Enum.reduce_while(items, {[], 0, 0, false}, fn item, {acc, count, bytes, _} ->
        item_bytes = byte_fun.(item)

        cond do
          count + 1 > max_count -> {:halt, {acc, count, bytes, true}}
          bytes + item_bytes > max_bytes -> {:halt, {acc, count, bytes, true}}
          true -> {:cont, {[item | acc], count + 1, bytes + item_bytes, false}}
        end
      end)

    kept = Enum.reverse(reversed_kept)
    {kept, truncated or length(kept) < length(items)}
  end
end
