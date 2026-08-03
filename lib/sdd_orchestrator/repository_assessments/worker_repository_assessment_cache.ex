defmodule SddOrchestrator.RepositoryAssessments.WorkerRepositoryAssessmentCache do
  @moduledoc """
  Bounded memory-only cache for complete exact-commit worker evidence.

  The cache is local to its worker process. It deliberately has no durable or
  hosted adapter: stopping or restarting the process discards every entry. Both
  entry count and encoded evidence bytes are capped, with least-recently-used
  entries evicted before a completed value is accepted.
  """

  use GenServer

  alias SddOrchestrator.RepositoryAssessments.{
    RepositoryAssessmentResult,
    WorkerRepositoryAssessment,
    WorkerRepositoryAssessmentCacheEntry
  }

  @hard_max_entries 64
  @hard_max_bytes 16 * 1_024 * 1_024
  @default_max_entries 32
  @default_max_bytes 8 * 1_024 * 1_024

  @type server :: GenServer.server()
  @type cache_error ::
          :conflicting_evidence | :entry_too_large | :incomplete_result | :invalid_result

  @doc "Starts one unnamed worker-local cache unless a worker supplies a name."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    with {:ok, state} <- initial_state(opts) do
      case Keyword.get(opts, :name) do
        nil -> GenServer.start_link(__MODULE__, state)
        name -> GenServer.start_link(__MODULE__, state, name: name)
      end
    end
  end

  @doc "Returns complete evidence only for the exact current cache key."
  @spec fetch(server(), term()) ::
          {:hit, map(), WorkerRepositoryAssessmentCacheEntry.provenance()} | :miss
  def fetch(server, command) do
    case WorkerRepositoryAssessmentCacheEntry.key(command) do
      {:ok, key} -> GenServer.call(server, {:fetch, key, command})
      {:error, :invalid_command} -> :miss
    end
  end

  @doc "Inserts only one strict completed result."
  @spec put(server(), term()) ::
          {:ok, WorkerRepositoryAssessmentCacheEntry.provenance()} | {:error, cache_error()}
  def put(server, result) do
    with {:ok, entry} <- WorkerRepositoryAssessmentCacheEntry.new(result) do
      GenServer.call(server, {:put, entry})
    end
  end

  @doc "Uses a complete hit or scans once and stores only the validated completion."
  @spec scan(server(), Path.t(), term(), keyword()) ::
          {:ok, map(), WorkerRepositoryAssessmentCacheEntry.provenance()}
          | {:error, atom()}
  def scan(server, repository_path, command, opts \\ []) do
    case fetch(server, command) do
      {:hit, worker_result, provenance} ->
        {:ok, worker_result, provenance}

      :miss ->
        scan_and_cache(server, repository_path, command, opts)
    end
  end

  @doc false
  @spec stats(server()) :: map()
  def stats(server), do: GenServer.call(server, :stats)

  @doc false
  @spec reset(server()) :: :ok
  def reset(server), do: GenServer.call(server, :reset)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:fetch, key, command}, _from, state) do
    case Map.fetch(state.entries, key) do
      {:ok, cached} ->
        case WorkerRepositoryAssessmentCacheEntry.reuse(cached.entry, command) do
          {:ok, worker_result} ->
            access = state.access + 1
            cached = %{cached | last_access: access}
            state = %{state | entries: Map.put(state.entries, key, cached), access: access}

            provenance =
              WorkerRepositoryAssessmentCacheEntry.provenance(
                cached.entry,
                "complete_cache",
                true
              )

            {:reply, {:hit, worker_result, provenance}, state}

          {:error, _invalid} ->
            {:reply, :miss, delete_entry(state, key)}
        end

      :error ->
        {:reply, :miss, state}
    end
  end

  @impl true
  def handle_call({:put, entry}, _from, state) do
    cond do
      entry.encoded_bytes > state.max_bytes ->
        {:reply, {:error, :entry_too_large}, state}

      true ->
        put_entry(state, entry)
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    {:reply,
     %{
       entries: map_size(state.entries),
       encoded_bytes: state.encoded_bytes,
       max_entries: state.max_entries,
       max_bytes: state.max_bytes,
       restart_policy: :discard_all
     }, state}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    {:reply, :ok, %{state | entries: %{}, encoded_bytes: 0, access: 0}}
  end

  defp scan_and_cache(server, repository_path, command, opts) do
    {scanner, scanner_opts} =
      Keyword.pop(opts, :scanner, &WorkerRepositoryAssessment.scan/3)

    if is_function(scanner, 3) do
      with {:ok, worker_result} <- scanner.(repository_path, command, scanner_opts),
           {:ok, result} <- RepositoryAssessmentResult.completed(command, worker_result),
           {:ok, entry} <- WorkerRepositoryAssessmentCacheEntry.new(result) do
        case put(server, result) do
          {:ok, _provenance} ->
            {:ok, worker_result,
             WorkerRepositoryAssessmentCacheEntry.provenance(entry, "fresh_scan", true)}

          {:error, :entry_too_large} ->
            {:ok, worker_result,
             WorkerRepositoryAssessmentCacheEntry.provenance(entry, "fresh_scan", false)}

          {:error, reason} ->
            {:error, reason}
        end
      end
    else
      {:error, :invalid_command}
    end
  end

  defp put_entry(state, entry) do
    case Map.fetch(state.entries, entry.key) do
      {:ok, %{entry: existing}} when existing.evidence_sha256 != entry.evidence_sha256 ->
        {:reply, {:error, :conflicting_evidence}, state}

      existing ->
        access = state.access + 1
        state = replace_entry(state, entry, existing, access)
        state = evict_to_limits(state)

        provenance =
          WorkerRepositoryAssessmentCacheEntry.provenance(entry, "fresh_scan", true)

        {:reply, {:ok, provenance}, state}
    end
  end

  defp replace_entry(state, entry, existing, access) do
    previous_bytes =
      case existing do
        {:ok, cached} -> cached.entry.encoded_bytes
        :error -> 0
      end

    cached = %{entry: entry, last_access: access}

    %{
      state
      | entries: Map.put(state.entries, entry.key, cached),
        encoded_bytes: state.encoded_bytes - previous_bytes + entry.encoded_bytes,
        access: access
    }
  end

  defp evict_to_limits(state) do
    if map_size(state.entries) <= state.max_entries and
         state.encoded_bytes <= state.max_bytes do
      state
    else
      {key, _cached} =
        Enum.min_by(state.entries, fn {_key, cached} ->
          {cached.last_access, cached.entry.cache_key_sha256}
        end)

      state
      |> delete_entry(key)
      |> evict_to_limits()
    end
  end

  defp delete_entry(state, key) do
    case Map.pop(state.entries, key) do
      {nil, _entries} ->
        state

      {cached, entries} ->
        %{
          state
          | entries: entries,
            encoded_bytes: state.encoded_bytes - cached.entry.encoded_bytes
        }
    end
  end

  defp initial_state(opts) when is_list(opts) do
    max_entries = Keyword.get(opts, :max_entries, @default_max_entries)
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)

    if is_integer(max_entries) and max_entries > 0 and max_entries <= @hard_max_entries and
         is_integer(max_bytes) and max_bytes > 0 and max_bytes <= @hard_max_bytes do
      {:ok,
       %{
         entries: %{},
         encoded_bytes: 0,
         access: 0,
         max_entries: max_entries,
         max_bytes: max_bytes
       }}
    else
      {:error, :invalid_cache_limits}
    end
  end

  defp initial_state(_opts), do: {:error, :invalid_cache_limits}
end
