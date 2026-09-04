defmodule SddOrchestrator.Worker.RepositoryScan do
  @moduledoc """
  The worker release's side of one repository scan: run the bounded scanner
  over the folder this worker is already holding for a binding, and answer
  with what it found.

  ## It never asks for the folder

  A scan names the same `selection_ref` the binding was verified under, and
  `SddOrchestrator.Worker.RepositoryMetadata` is still holding the folder that
  reference resolved to. This module reads it from there and refuses with
  `selection_expired` when the hold is gone. It never calls
  `SddOrchestrator.Worker.RepositorySelection`, so no panel can open on a
  person's Mac because a scan arrived.

  That refusal is the ordinary case, not the rare one. A hold lives as long as
  the metadata request that created it, and a scan follows a person reading a
  processing boundary and pressing a button. The control plane turns the
  refusal into a stored failure and the screen asks them to verify the binding
  again, which is the agreed behaviour rather than a fallback.

  ## The scan runs beside this process, not inside it

  `RepositoryAssessments.WorkerRepositoryAssessmentCache.scan_with_proposal/4`
  reads a repository and can take seconds. Running it in this process would
  make a cancellation wait for the scan it is trying to stop, so each scan
  runs in its own monitored task and this process stays free to take the
  cancel. Cancelling kills that task, which is safe because the scanner only
  ever reads: it performs no checkout and no repository write, so there is no
  half-finished state a kill could leave behind.

  Scans are keyed by the control plane's `request_id`, and more than one may
  be in flight. The exact-commit cache in front of the scanner makes a repeat
  question cheap rather than a second full read.

  ## The privacy discipline

  The held path lives only in this process's local variables and in the task
  it starts. It is never logged, at any level, and it is never part of an
  answer. What is answered is what the scanner already minimized: findings,
  structure, stats, and the six proposal fields derived from them.
  """

  use GenServer

  require Logger

  alias SddOrchestrator.RepositoryAssessments.RepositoryAssessmentCommand
  alias SddOrchestrator.RepositoryAssessments.RepositoryExecutionProfileProposalPayload
  alias SddOrchestrator.RepositoryAssessments.WorkerRepositoryAssessmentCache
  alias SddOrchestrator.Worker.RepositoryMetadata

  @typedoc "Sends one finished answer payload back to the control plane."
  @type reply :: (map() -> any())

  # The bounded scanner's own terminal errors, which are also the control
  # plane's allowlisted failure codes. Anything else a scan can end with is a
  # defect or a cache refusal, and becomes the same generic refusal.
  @scanner_reasons ~w(
    file_limit_exceeded file_size_limit_exceeded invalid_command path_limit_exceeded
    repository_unavailable root_escape stale_commit time_limit_exceeded
    total_byte_limit_exceeded
  )a

  @doc """
  Starts the scan holder for this worker release.

  `opts` may carry `:cache`, the worker-local exact-commit cache server to
  scan through; production callers pass none and the supervised one is used.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Takes one scan request that arrived from the control plane.

  `payload` is the decoded inbound message (`request_id`, `selection_ref`,
  `command`, `expires_at`) and `reply` is called exactly once with the
  finished answer payload: a `"scanned"`, a `"refused"`, or a `"cancelled"`
  outcome.

  Cast rather than called, because the caller is the gateway connection's own
  callback and it must never wait on a repository read to keep serving the
  socket. A request that arrives with no usable id or an unreadable command is
  dropped, which the control plane already reports as a request the worker
  never answered.
  """
  @spec open(map(), reply()) :: :ok
  def open(payload, reply) when is_map(payload) and is_function(reply, 1) do
    GenServer.cast(__MODULE__, {:open, payload, reply})
  end

  @doc """
  Cancels the in-flight scan named by its wire `request_id`.

  An id that names no scan this process is running changes nothing, the same
  way a mismatched id changes nothing for the metadata question.
  """
  @spec close(String.t()) :: :ok
  def close(request_id) when is_binary(request_id) do
    GenServer.cast(__MODULE__, {:close, request_id})
  end

  @impl GenServer
  def init(opts) do
    {:ok,
     %{
       cache: Keyword.get(opts, :cache, WorkerRepositoryAssessmentCache),
       running: %{},
       refs: %{}
     }}
  end

  @impl GenServer
  def handle_cast({:open, payload, reply}, state) do
    case parse_request(payload) do
      {:ok, request} -> {:noreply, start_scan(request, reply, state)}
      :error -> {:noreply, state}
    end
  end

  def handle_cast({:close, request_id}, state) do
    case Map.fetch(state.running, request_id) do
      {:ok, scan} ->
        Process.demonitor(scan.ref, [:flush])
        Process.exit(scan.pid, :kill)
        scan.reply.(%{"request_id" => request_id, "outcome" => "cancelled"})
        {:noreply, forget(state, request_id, scan.ref)}

      :error ->
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info({:scanned, request_id, outcome}, state) do
    case Map.fetch(state.running, request_id) do
      {:ok, scan} ->
        Process.demonitor(scan.ref, [:flush])
        scan.reply.(answer(request_id, outcome))
        {:noreply, forget(state, request_id, scan.ref)}

      # A cancellation that won the race already answered this request.
      :error ->
        {:noreply, state}
    end
  end

  # The task died without answering. A killed task is a cancellation, which
  # has already answered and forgotten the scan, so anything reaching here is
  # a genuine crash and becomes the same refusal a failed read would.
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.fetch(state.refs, ref) do
      {:ok, request_id} ->
        scan = Map.fetch!(state.running, request_id)
        Logger.error("worker repository scan task ended: #{inspect(reason)}")
        scan.reply.(answer(request_id, {:error, :repository_unavailable}))
        {:noreply, forget(state, request_id, ref)}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  # The folder is read before the task starts, so a hold that is already gone
  # is refused without spawning anything.
  defp start_scan(request, reply, state) do
    case RepositoryMetadata.held_path(request.selection_ref) do
      {:ok, path} -> run(request, path, reply, state)
      :none -> answer_now(request, reply, {:error, :selection_expired}, state)
    end
  end

  defp run(request, path, reply, state) do
    holder = self()
    cache = state.cache

    {pid, ref} =
      spawn_monitor(fn ->
        outcome = scan(cache, path, request.command)
        send(holder, {:scanned, request.request_id, outcome})
      end)

    %{
      state
      | running: Map.put(state.running, request.request_id, %{pid: pid, ref: ref, reply: reply}),
        refs: Map.put(state.refs, ref, request.request_id)
    }
  end

  defp scan(cache, path, command) do
    case WorkerRepositoryAssessmentCache.scan_with_proposal(cache, path, command) do
      {:ok, worker_result, payload, _envelope, _provenance} -> {:ok, worker_result, payload}
      {:error, reason} -> {:error, reason}
    end
  end

  defp answer_now(request, reply, outcome, state) do
    reply.(answer(request.request_id, outcome))
    state
  end

  defp answer(request_id, {:ok, worker_result, payload}) do
    %{
      "request_id" => request_id,
      "outcome" => "scanned",
      "findings" => worker_result.findings,
      "structure" => worker_result.structure,
      "stats" => worker_result.stats,
      "proposal" => RepositoryExecutionProfileProposalPayload.proposal_fields(payload)
    }
  end

  defp answer(request_id, {:error, :canceled}) do
    %{"request_id" => request_id, "outcome" => "cancelled"}
  end

  defp answer(request_id, {:error, reason}) do
    %{"request_id" => request_id, "outcome" => "refused", "reason" => wire_reason(reason)}
  end

  defp wire_reason(:selection_expired), do: "selection_expired"
  defp wire_reason(reason) when reason in @scanner_reasons, do: Atom.to_string(reason)
  defp wire_reason(_other), do: "repository_unavailable"

  defp forget(state, request_id, ref) do
    %{state | running: Map.delete(state.running, request_id), refs: Map.delete(state.refs, ref)}
  end

  defp parse_request(payload) do
    with {:ok, request_id} <- fetch_id(payload, "request_id"),
         {:ok, selection_ref} <- fetch_id(payload, "selection_ref"),
         {:ok, command} <- fetch_command(payload) do
      {:ok, %{request_id: request_id, selection_ref: selection_ref, command: command}}
    else
      :error ->
        Logger.warning(
          "worker ignoring a repository scan request with no request id, selection ref, or command"
        )

        :error
    end
  end

  defp fetch_id(payload, key) do
    case Map.get(payload, key) do
      id when is_binary(id) and id != "" -> {:ok, id}
      _unusable -> :error
    end
  end

  defp fetch_command(payload) do
    with value when is_map(value) <- Map.get(payload, "command"),
         {:ok, command} <- RepositoryAssessmentCommand.from_value(value) do
      {:ok, command}
    else
      _unusable -> :error
    end
  end
end
