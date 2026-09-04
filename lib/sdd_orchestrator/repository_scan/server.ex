defmodule SddOrchestrator.RepositoryScan.Server do
  @moduledoc """
  The in-memory table of open scan requests and the single outcome each one ends in.

  Scanning a repository takes a worker real time. The caller does not return
  early the way a folder-selection request does: `run/2` blocks the calling
  process until evidence, a refusal, a cancellation, a timeout, or the loss of
  the worker's attachment settles the request, and this server is what makes
  that block safe.

  No outcome is ever sent as a message to the caller's mailbox.
  `handle_call({:run, ...})` stores the caller's `from` and returns
  `{:noreply, state}` instead of replying at once when the push succeeds; the
  reply is sent later, exactly once, through `GenServer.reply/2` from
  whichever path settles the request: a worker's answer, the worker's channel
  going down, the requester itself going down, or this server's own expiry
  timer. `GenServer.reply/2` to a caller that has already exited is a safe
  no-op, which is what lets the requester's own exit end a request with
  nothing left to do but clean up and cancel.

  Every way out of a request removes the entry first and replies second, so a
  requester's blocked call resolves exactly once. An answer arriving after the
  request is gone finds nothing to deliver to, which is what makes a late
  answer, a repeat answer, and an answer to an expired request all harmless.

  This is deliberately the same shape as
  `SddOrchestrator.RepositoryMetadata.Server`, which owns the smaller question
  over the same attachment. The two are not merged because their requests,
  answers, wait windows, and refusal vocabularies differ; the lifecycle they
  share is the part worth having twice rather than generalising into a third
  module that neither would own.

  Nothing here is persisted. Nothing in the table holds an absolute path, and
  the only thing ever logged from it is that a request timed out.
  """
  use GenServer

  require Logger

  alias SddOrchestrator.RepositoryScan.ScanAnswer
  alias SddOrchestrator.RepositoryScan.ScanRequest
  alias SddOrchestrator.RepositoryScan.Transport

  @name __MODULE__

  @typedoc "What a blocked caller is told, once, about its request."
  @type outcome :: {:ok, map()} | {:error, atom()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @doc """
  Pushes one request to the worker and blocks the calling process until its
  outcome is known.

  The outer call is given `:infinity` so it can never time out the caller;
  this server owns the actual expiry through its own timer and replies
  through `GenServer.reply/2` when that timer fires.
  """
  @spec run(map(), pos_integer()) :: outcome()
  def run(attrs, timeout_ms) do
    GenServer.call(@name, {:run, attrs, timeout_ms}, :infinity)
  end

  @doc "Delivers one worker answer to the request it is for, or refuses it."
  @spec answer(map(), map()) ::
          :ok | {:error, :unknown_request | :foreign_answer | :invalid_result}
  def answer(answering, attrs), do: GenServer.call(@name, {:answer, answering, attrs})

  @impl true
  def init(_opts), do: {:ok, %{requests: %{}, monitors: %{}}}

  @impl true
  def handle_call({:run, attrs, timeout_ms}, from, state) do
    request = build(attrs, elem(from, 0), timeout_ms)

    case Transport.transport().push(request) do
      {:ok, channel} when is_pid(channel) ->
        {:noreply, track(state, request, channel, timeout_ms, from)}

      {:error, reason} ->
        Logger.debug("repository scan push refused: #{reason}")
        {:reply, {:error, :worker_unavailable}, state}

      _unexpected ->
        {:reply, {:error, :worker_unavailable}, state}
    end
  end

  def handle_call({:answer, answering, attrs}, _from, state) do
    with {:ok, request_id} <- answered_request_id(attrs),
         {:ok, entry} <- fetch_open(state, request_id),
         :ok <- same_attachment(entry.request, answering),
         {:ok, answer} <- ScanAnswer.new(attrs) do
      {:reply, :ok, deliver(state, request_id, requester_outcome(answer))}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, state) do
    case Map.fetch(state.monitors, monitor_ref) do
      {:ok, {:requester, request_id}} ->
        {:noreply, requester_gone(state, request_id)}

      {:ok, {:worker, request_id}} ->
        {:noreply, deliver(state, request_id, {:error, :worker_unavailable})}

      :error ->
        {:noreply, state}
    end
  end

  # A timer that fired while its request was being answered names a request
  # that is already gone, so an unknown id is simply ignored.
  def handle_info({:expired, request_id}, state) do
    case Map.fetch(state.requests, request_id) do
      {:ok, entry} ->
        Logger.debug("repository scan request #{request_id} timed out")
        state = discard(state, request_id)
        Transport.transport().cancel(entry.request)
        GenServer.reply(entry.from, {:error, :worker_unavailable})
        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp build(attrs, requester, timeout_ms) do
    %ScanRequest{
      id: Ecto.UUID.generate(),
      requester: requester,
      device_workspace_id: attrs.device_workspace_id,
      project_id: attrs.project_id,
      worker_id: attrs.worker_ref,
      selection_ref: attrs.selection_ref,
      command: attrs.command,
      expires_at: DateTime.add(DateTime.utc_now(), timeout_ms, :millisecond)
    }
  end

  # Both the requester and the worker's channel are watched, because either
  # one disappearing ends the request: one with nobody left to reply to, the
  # other with a `:worker_unavailable` reply to send.
  defp track(state, request, channel, timeout_ms, from) do
    requester_ref = Process.monitor(elem(from, 0))
    worker_ref = Process.monitor(channel)
    timer = Process.send_after(self(), {:expired, request.id}, timeout_ms)

    entry = %{
      request: request,
      from: from,
      requester_ref: requester_ref,
      worker_ref: worker_ref,
      timer: timer
    }

    %{
      state
      | requests: Map.put(state.requests, request.id, entry),
        monitors:
          state.monitors
          |> Map.put(requester_ref, {:requester, request.id})
          |> Map.put(worker_ref, {:worker, request.id})
    }
  end

  # Removing the entry before replying is what guarantees one outcome per
  # request: a second attempt finds nothing and replies to nobody.
  defp deliver(state, request_id, outcome) do
    case Map.fetch(state.requests, request_id) do
      {:ok, entry} ->
        state = discard(state, request_id)
        GenServer.reply(entry.from, outcome)
        state

      :error ->
        state
    end
  end

  # The requester is gone, so there is nobody to reply to. The worker is still
  # told to stop, exactly like an explicit cancellation.
  defp requester_gone(state, request_id) do
    case Map.fetch(state.requests, request_id) do
      {:ok, entry} ->
        state = discard(state, request_id)
        Transport.transport().cancel(entry.request)
        state

      :error ->
        state
    end
  end

  defp discard(state, request_id) do
    case Map.pop(state.requests, request_id) do
      {nil, _requests} ->
        state

      {entry, requests} ->
        Process.demonitor(entry.requester_ref, [:flush])
        Process.demonitor(entry.worker_ref, [:flush])
        Process.cancel_timer(entry.timer, info: false)

        %{
          state
          | requests: requests,
            monitors: Map.drop(state.monitors, [entry.requester_ref, entry.worker_ref])
        }
    end
  end

  defp answered_request_id(attrs) when is_map(attrs) do
    case Map.get(attrs, :request_id) || Map.get(attrs, "request_id") do
      request_id when is_binary(request_id) -> {:ok, request_id}
      _other -> {:error, :unknown_request}
    end
  end

  defp answered_request_id(_attrs), do: {:error, :unknown_request}

  defp fetch_open(state, request_id) do
    case Map.fetch(state.requests, request_id) do
      {:ok, entry} -> {:ok, entry}
      :error -> {:error, :unknown_request}
    end
  end

  # The attachment that answers must be the attachment the request was pushed
  # to. A worker may only ever answer its own workspace's request.
  defp same_attachment(%ScanRequest{} = request, answering) when is_map(answering) do
    workspace_id = Map.get(answering, :device_workspace_id)
    worker_id = Map.get(answering, :worker_id)

    if workspace_id == request.device_workspace_id and worker_id == request.worker_id do
      :ok
    else
      {:error, :foreign_answer}
    end
  end

  defp same_attachment(_request, _answering), do: {:error, :foreign_answer}

  defp requester_outcome(%ScanAnswer{outcome: :scanned} = answer) do
    {:ok,
     %{
       findings: answer.findings,
       structure: answer.structure,
       stats: answer.stats,
       proposal: answer.proposal,
       provenance: answer.provenance
     }}
  end

  defp requester_outcome(%ScanAnswer{outcome: :refused, reason: reason}), do: {:error, reason}
  defp requester_outcome(%ScanAnswer{outcome: :cancelled}), do: {:error, :cancelled}
end
