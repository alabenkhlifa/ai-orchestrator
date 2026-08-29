defmodule SddOrchestrator.RepositorySelection.Server do
  @moduledoc """
  The in-memory table of open selection requests and the single outcome each one ends in.

  A folder panel is answered by a person, so a request lives for tens of
  seconds while the process that made it goes on serving. This server holds
  that gap. It keeps one entry per open request, watches both the requester and
  the worker's channel, and arms one expiry timer.

  Every way out of a request removes the entry first and sends second, so a
  requester receives exactly one `{:repository_selection, request_id, outcome}`
  message and never a second one. An answer arriving after the request is gone
  finds nothing to deliver to, which is what makes a late answer, a repeat
  answer, and an answer to an expired request all harmless.

  Nothing here is persisted. Losing the table on restart is correct: no request
  survives a control-plane restart because no panel does either, and the person
  simply asks again. Nothing in the table holds a filesystem path, and no log
  line is written from it.
  """
  use GenServer

  alias SddOrchestrator.RepositorySelection.SelectionRequest
  alias SddOrchestrator.RepositorySelection.SelectionResult
  alias SddOrchestrator.RepositorySelection.Transport

  @name __MODULE__

  @typedoc "What a requester is told, once, about its request."
  @type outcome ::
          {:selected, SelectionResult.t()}
          | :cancelled
          | {:refused, SelectionResult.outcome()}
          | :timeout
          | :worker_lost

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @doc """
  Opens one request for the calling process and pushes it to the worker.

  The requester is taken from the caller rather than the arguments, so a
  request can only ever be bound to the process that actually asked.
  """
  @spec open(map(), pos_integer()) :: {:ok, String.t()} | {:error, Transport.reason()}
  def open(attrs, timeout_ms), do: GenServer.call(@name, {:open, attrs, timeout_ms})

  @doc "Closes the calling process's own open request and tells the worker to close its panel."
  @spec cancel(String.t()) :: :ok | {:error, :not_found | :not_owner}
  def cancel(request_id), do: GenServer.call(@name, {:cancel, request_id})

  @doc "Delivers one worker answer to the requester that asked, or refuses it."
  @spec answer(map(), map()) ::
          :ok | {:error, :unknown_request | :foreign_answer | :invalid_result}
  def answer(answering, attrs), do: GenServer.call(@name, {:answer, answering, attrs})

  @impl true
  def init(_opts), do: {:ok, %{requests: %{}, monitors: %{}}}

  @impl true
  def handle_call({:open, attrs, timeout_ms}, {requester, _tag}, state) do
    request = build(attrs, requester, timeout_ms)

    case Transport.transport().push(request) do
      {:ok, channel} when is_pid(channel) ->
        {:reply, {:ok, request.id}, track(state, request, channel, timeout_ms)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}

      _unexpected ->
        {:reply, {:error, :transport_error}, state}
    end
  end

  def handle_call({:cancel, request_id}, {caller, _tag}, state) do
    case Map.fetch(state.requests, request_id) do
      {:ok, %{request: %SelectionRequest{requester: ^caller} = request}} ->
        state = discard(state, request_id)
        Transport.transport().cancel(request)
        send(caller, {:repository_selection, request_id, :cancelled})
        {:reply, :ok, state}

      {:ok, _entry} ->
        {:reply, {:error, :not_owner}, state}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:answer, answering, attrs}, _from, state) do
    with {:ok, request_id} <- answered_request_id(attrs),
         {:ok, entry} <- fetch_open(state, request_id),
         :ok <- same_attachment(entry.request, answering),
         {:ok, result} <- SelectionResult.new(attrs) do
      {:reply, :ok, deliver(state, request_id, requester_outcome(result))}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, state) do
    case Map.fetch(state.monitors, monitor_ref) do
      {:ok, {:requester, request_id}} -> {:noreply, requester_gone(state, request_id)}
      {:ok, {:worker, request_id}} -> {:noreply, deliver(state, request_id, :worker_lost)}
      :error -> {:noreply, state}
    end
  end

  # A timer that fired while its request was being answered names a request
  # that is already gone, so an unknown id is simply ignored.
  def handle_info({:expired, request_id}, state) do
    case Map.fetch(state.requests, request_id) do
      {:ok, entry} ->
        state = discard(state, request_id)
        Transport.transport().cancel(entry.request)
        send(entry.request.requester, {:repository_selection, request_id, :timeout})
        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp build(attrs, requester, timeout_ms) do
    %SelectionRequest{
      id: Ecto.UUID.generate(),
      requester: requester,
      device_workspace_id: attrs.device_workspace_id,
      project_id: Map.get(attrs, :project_id),
      worker_id: attrs.worker_id,
      candidates: attrs.candidates,
      generate?: attrs.generate?,
      expires_at: DateTime.add(DateTime.utc_now(), timeout_ms, :millisecond)
    }
  end

  # Both the requester and the worker's channel are watched, because either one
  # disappearing ends the request: one with nobody left to tell, the other with
  # a `:worker_lost` to tell.
  defp track(state, request, channel, timeout_ms) do
    requester_ref = Process.monitor(request.requester)
    worker_ref = Process.monitor(channel)
    timer = Process.send_after(self(), {:expired, request.id}, timeout_ms)

    entry = %{
      request: request,
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

  # Removing the entry before sending is what guarantees one outcome per
  # request: a second attempt finds nothing and sends nothing.
  defp deliver(state, request_id, outcome) do
    case Map.fetch(state.requests, request_id) do
      {:ok, entry} ->
        state = discard(state, request_id)
        send(entry.request.requester, {:repository_selection, request_id, outcome})
        state

      :error ->
        state
    end
  end

  # The requester is gone, so there is nobody to tell. The worker is told, so
  # the panel on the person's Mac closes instead of hanging on a dead tab.
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
  # to. A worker may only ever close its own workspace's request.
  defp same_attachment(%SelectionRequest{} = request, answering) when is_map(answering) do
    workspace_id = Map.get(answering, :device_workspace_id)
    worker_id = Map.get(answering, :worker_id)

    if workspace_id == request.device_workspace_id and worker_id == request.worker_id do
      :ok
    else
      {:error, :foreign_answer}
    end
  end

  defp same_attachment(_request, _answering), do: {:error, :foreign_answer}

  defp requester_outcome(%SelectionResult{outcome: :selected} = result), do: {:selected, result}
  defp requester_outcome(%SelectionResult{outcome: :cancelled}), do: :cancelled
  defp requester_outcome(%SelectionResult{outcome: refusal}), do: {:refused, refusal}
end
