defmodule SddOrchestratorWeb.PersonalAIWorkerChannel do
  @moduledoc """
  One paired worker's personal AI session for one device workspace.

  The socket already authenticated the pairing credential; the joined topic
  must name the same device workspace, and the versioned AI capability
  contract is negotiated before the worker is addressable. Exactly one live
  connection exists per paired worker: a reconnect replaces the stale
  registration deterministically, failing that registration's pending
  requests with a typed error so no caller waits on a dead connection.

  Control-plane requests arrive as messages, are pushed to the worker as
  `"ai_request"` frames, and are answered with `"ai_response"` frames
  correlated by request id. A bounded completed-response cache keyed by
  idempotency key answers a repeated request without re-contacting the
  worker; reusing a key with different content is refused.

  Refusal is whole. A malformed, oversized, mis-scoped, replayed, or
  unexpected frame changes nothing and is answered with a typed reason while
  the session stays open, so one bad frame does not cost a correct worker its
  connection.

  This transport is isolated from the Slice 07 run gateway on purpose: the
  run gateway's message names are refused by name, and no command outbox,
  delivery transport, or delivery topic is reachable from here.
  """
  use Phoenix.Channel

  alias SddOrchestrator.AIRuntime.PersonalWorkerProtocol
  alias SddOrchestrator.AIRuntime.PersonalWorkerRPC
  alias SddOrchestrator.Devices.LocalWorker
  alias SddOrchestrator.Devices.Pairing
  alias SddOrchestrator.Repo

  @project_run_commands PersonalWorkerProtocol.project_run_commands()

  # Replacement is deterministic but not instantaneous: the stale channel must
  # process its stop before the registry frees the key, so a joining channel
  # retries briefly instead of failing a legitimate reconnect.
  @register_attempts 20
  @register_retry_ms 25

  @impl true
  def join("personal_ai:" <> topic_workspace, params, socket) do
    with {:ok, workspace_id} <- cast_workspace(topic_workspace),
         :ok <- authorize_workspace(workspace_id, socket),
         {:ok, contract} <- PersonalWorkerProtocol.negotiate(params),
         :ok <- register(socket, contract, @register_attempts) do
      {:ok, contract,
       socket
       |> assign(:contract, contract)
       |> assign(:pending, %{})
       |> assign(:completed, %{})
       |> assign(:completed_order, :queue.new())}
    else
      {:error, reason} -> {:error, refusal(reason)}
    end
  end

  def join(_topic, _params, _socket), do: {:error, %{reason: "unknown_topic"}}

  @impl true
  def handle_in("ai_response", payload, socket) do
    case accept_response(payload, socket) do
      {:ok, socket} -> {:reply, {:ok, %{status: "completed"}}, socket}
      {:error, reason, socket} -> {:reply, {:error, refusal(reason)}, socket}
    end
  end

  # The Slice 07 run gateway's message names are refused by name with their
  # own reason, so this transport can never quietly become a second run
  # gateway. The session stays open: refusal is an answer, not a disconnect.
  def handle_in(event, _payload, socket) when event in @project_run_commands,
    do: {:reply, {:error, %{reason: "project_run_command_refused"}}, socket}

  def handle_in(_event, _payload, socket),
    do: {:reply, {:error, %{reason: "unsupported_message"}}, socket}

  @impl true
  def handle_info({:ai_request, envelope, caller, ref, deadline}, socket) do
    case admit(envelope, socket) do
      :push ->
        {:noreply, track_and_push(envelope, caller, ref, deadline, socket)}

      {:cached, reply} ->
        respond(caller, ref, reply)
        {:noreply, socket}

      {:refuse, reason} ->
        respond(caller, ref, {:error, reason})
        {:noreply, socket}
    end
  end

  def handle_info({:cancel_ai_request, request_id}, socket) do
    case Map.fetch(socket.assigns.pending, request_id) do
      {:ok, entry} -> {:noreply, drop_pending(socket, request_id, entry)}
      :error -> {:noreply, socket}
    end
  end

  # A replaced channel answers every pending caller before it stops, so no
  # request is left waiting on a connection that no longer exists. The
  # registry entry is released by the stop itself.
  def handle_info({:replaced_by, _successor}, socket) do
    {:stop, {:shutdown, :replaced}, fail_pending(socket, :worker_disconnected)}
  end

  # A caller that stopped waiting can no longer receive its response; its
  # pending entries are dropped so a late frame is refused as a replay.
  def handle_info({:DOWN, monitor, :process, _caller, _reason}, socket) do
    abandoned =
      for {request_id, entry} <- socket.assigns.pending, entry.monitor == monitor do
        {request_id, entry}
      end

    {:noreply,
     Enum.reduce(abandoned, socket, fn {request_id, entry}, socket ->
       drop_pending(socket, request_id, entry)
     end)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # ---- join ----

  defp cast_workspace(topic_workspace) do
    case Ecto.UUID.cast(topic_workspace) do
      {:ok, workspace_id} -> {:ok, workspace_id}
      :error -> {:error, :unknown_topic}
    end
  end

  # The socket authenticated one paired worker; the topic is where that worker
  # could otherwise reach across workspaces. The worker row is re-read so a
  # revocation between connect and join is also caught.
  defp authorize_workspace(workspace_id, socket) do
    case Repo.get(LocalWorker, socket.assigns.worker_id) do
      %LocalWorker{} = worker -> Pairing.authorize_for_workspace(worker, workspace_id)
      nil -> {:error, :unauthorized}
    end
  end

  defp register(_socket, _contract, 0), do: {:error, :registration_conflict}

  defp register(socket, contract, attempts) do
    case PersonalWorkerRPC.attach(
           socket.assigns.device_workspace_id,
           socket.assigns.worker_id,
           contract
         ) do
      {:ok, _owner} ->
        :ok

      {:error, {:already_registered, stale}} ->
        send(stale, {:replaced_by, self()})
        Process.sleep(@register_retry_ms)
        register(socket, contract, attempts - 1)
    end
  end

  # ---- outbound requests ----

  defp admit(envelope, socket) do
    with :ok <-
           PersonalWorkerProtocol.validate_request(envelope, socket.assigns.contract.capabilities),
         :ok <- confirm_request_workspace(envelope, socket),
         :ok <- confirm_unclaimed(envelope, socket) do
      cached(envelope, socket)
    else
      {:error, reason} -> {:refuse, reason}
    end
  end

  # The registry key already routes a request to the worker its workspace
  # names; this re-check is defense in depth against a caller that addressed
  # the channel directly with someone else's workspace in the envelope.
  defp confirm_request_workspace(envelope, socket) do
    if envelope["device_workspace_id"] == socket.assigns.device_workspace_id,
      do: :ok,
      else: {:error, :cross_workspace}
  end

  defp confirm_unclaimed(envelope, socket) do
    pending = socket.assigns.pending
    key = envelope["idempotency_key"]

    in_flight? =
      Map.has_key?(pending, envelope["request_id"]) or
        Enum.any?(pending, fn {_request_id, entry} -> entry.idempotency_key == key end)

    if in_flight?, do: {:error, :duplicate_request}, else: :ok
  end

  defp cached(envelope, socket) do
    case Map.fetch(socket.assigns.completed, envelope["idempotency_key"]) do
      :error ->
        :push

      {:ok, %{signature: signature, reply: reply}} ->
        if signature == PersonalWorkerProtocol.request_signature(envelope),
          do: {:cached, reply},
          else: {:refuse, :duplicate_request}
    end
  end

  defp track_and_push(envelope, caller, ref, deadline, socket) do
    entry = %{
      caller: caller,
      ref: ref,
      monitor: Process.monitor(caller),
      account_id: envelope["account_id"],
      idempotency_key: envelope["idempotency_key"],
      signature: PersonalWorkerProtocol.request_signature(envelope),
      deadline: deadline
    }

    push(socket, "ai_request", envelope)

    assign(socket, :pending, Map.put(socket.assigns.pending, envelope["request_id"], entry))
  end

  # ---- inbound responses ----

  defp accept_response(payload, socket) do
    case PersonalWorkerProtocol.validate_response(payload) do
      :ok -> route_response(payload, socket)
      {:error, reason} -> {:error, reason, socket}
    end
  end

  defp route_response(%{"request_id" => request_id} = payload, socket) do
    case Map.fetch(socket.assigns.pending, request_id) do
      :error ->
        # Unknown or already completed: a second answer must change nothing.
        {:error, :replayed_response, socket}

      {:ok, entry} ->
        deliver_response(payload, request_id, entry, socket)
    end
  end

  defp deliver_response(payload, request_id, entry, socket) do
    cond do
      payload["account_id"] != entry.account_id ->
        # The response must answer for exactly the account scope the request
        # was bound to; the request stays pending for the correct answer.
        {:error, :cross_account, socket}

      expired?(entry) ->
        # The caller already stopped waiting; the late answer is a replay.
        {:error, :replayed_response, drop_pending(socket, request_id, entry)}

      true ->
        reply = {:ok, payload["result"]}
        respond(entry.caller, entry.ref, reply)

        {:ok,
         socket
         |> drop_pending(request_id, entry)
         |> cache_completed(entry, reply)}
    end
  end

  defp expired?(entry), do: System.monotonic_time(:millisecond) > entry.deadline

  defp cache_completed(socket, entry, reply) do
    completed =
      Map.put(socket.assigns.completed, entry.idempotency_key, %{
        signature: entry.signature,
        reply: reply
      })

    order = :queue.in(entry.idempotency_key, socket.assigns.completed_order)
    {completed, order} = enforce_cache_bound(completed, order)

    socket
    |> assign(:completed, completed)
    |> assign(:completed_order, order)
  end

  defp enforce_cache_bound(completed, order) do
    if map_size(completed) > PersonalWorkerProtocol.limit(:max_completed_responses) do
      {{:value, oldest}, order} = :queue.out(order)
      {Map.delete(completed, oldest), order}
    else
      {completed, order}
    end
  end

  # ---- shared ----

  defp drop_pending(socket, request_id, entry) do
    Process.demonitor(entry.monitor, [:flush])
    assign(socket, :pending, Map.delete(socket.assigns.pending, request_id))
  end

  defp fail_pending(socket, reason) do
    Enum.each(socket.assigns.pending, fn {_request_id, entry} ->
      Process.demonitor(entry.monitor, [:flush])
      respond(entry.caller, entry.ref, {:error, reason})
    end)

    assign(socket, :pending, %{})
  end

  defp respond(caller, ref, reply), do: send(caller, {PersonalWorkerRPC, ref, reply})

  defp refusal(reason) when is_atom(reason), do: %{reason: Atom.to_string(reason)}
  defp refusal(_reason), do: %{reason: "unavailable"}
end
