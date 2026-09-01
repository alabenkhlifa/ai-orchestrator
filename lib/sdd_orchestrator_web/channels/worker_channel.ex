defmodule SddOrchestratorWeb.WorkerChannel do
  @moduledoc """
  One authenticated worker's protocol session for one project.

  Everything a worker may do is bounded by the credential the socket already
  verified. The joined topic must name the same project, the versioned
  capability contract is negotiated before the worker is attachable for
  delivery, and every inbound envelope passes the shared codec before it is
  allowed to mean anything.

  Refusal is whole. A malformed, oversized, mis-scoped, or unexpected frame
  changes nothing and is answered with a reason, while the session stays open
  so one bad frame does not cost a correct worker its run.

  Nothing is announced that a reader cannot find afterwards. An acknowledgement
  goes straight to the durable outbox, and an event this control plane turns
  into activity is stored before it is published and before the worker is told
  `accepted`. A worker that hears its progress was taken can therefore trust
  that the run's history holds it.

  The rest of a project's state belongs to the modules that own it. Heartbeats,
  reconciliation snapshots, and the event types owned outside `EventIngestion`
  are published for the tasks that give them meaning.
  """
  use Phoenix.Channel

  alias Phoenix.PubSub
  alias SddOrchestrator.Accounts.PersonalWorkspace
  alias SddOrchestrator.Delivery.CommandOutbox
  alias SddOrchestrator.Delivery.CommandTransport.Channel, as: Transport
  alias SddOrchestrator.Delivery.EventIngestion
  alias SddOrchestrator.Delivery.ProtocolCodec
  alias SddOrchestrator.Delivery.WorkerProtocol
  alias SddOrchestrator.Projects.Project
  alias SddOrchestrator.Repo

  @doc "The PubSub topic carrying one project's validated worker traffic."
  @spec topic(Ecto.UUID.t()) :: String.t()
  def topic(project_id), do: "delivery:worker:#{project_id}"

  @impl true
  def join("worker:" <> project_id, params, socket) do
    with :ok <- confirm_execution_target(project_id, socket),
         {:ok, contract} <- WorkerProtocol.negotiate(params),
         {:ok, _worker} <- attach(project_id, contract, socket) do
      {:ok, contract, assign(socket, :contract, contract)}
    else
      {:error, reason} -> {:error, refusal(reason)}
    end
  end

  def join(_topic, _params, _socket), do: {:error, %{reason: "unknown_topic"}}

  @impl true
  def handle_in("acknowledge", payload, socket) do
    case acknowledge(payload, socket) do
      {:ok, state} -> {:reply, {:ok, %{status: state}}, socket}
      {:error, reason} -> {:reply, {:error, refusal(reason)}, socket}
    end
  end

  def handle_in("heartbeat", payload, socket) do
    case accept(payload, "heartbeat", socket) do
      {:ok, envelope} ->
        publish(socket, {:worker_heartbeat, envelope})
        {:reply, {:ok, %{status: "recorded"}}, assign(socket, :liveness, liveness(envelope))}

      {:error, reason} ->
        {:reply, {:error, refusal(reason)}, socket}
    end
  end

  def handle_in("event", payload, socket) do
    with {:ok, envelope} <- accept(payload, "event", socket),
         :ok <- store(envelope, socket) do
      publish(socket, {:worker_event, envelope})
      {:reply, {:ok, %{status: "accepted"}}, socket}
    else
      {:error, reason} -> {:reply, {:error, refusal(reason)}, socket}
    end
  end

  def handle_in("reconcile", payload, socket),
    do: intake(payload, "reconciliation_snapshot", :worker_reconciliation, socket)

  def handle_in(_event, _payload, socket),
    do: {:reply, {:error, %{reason: "unsupported_message"}}, socket}

  @impl true
  def handle_info({:deliver_command, envelope}, socket) do
    push(socket, "command", envelope)
    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # The socket authenticated one execution target; the topic is where a worker
  # would otherwise reach across projects, so it is checked before negotiation
  # and therefore before the worker can be sent anything.
  #
  # A socket holding no project at all, such as a Mac-scoped one, matches no
  # topic here, because the value it would be compared against is absent rather
  # than wrong. Reading the assign directly raised on that socket and killed the
  # channel process instead of answering it, which turned a refusal into a
  # crash. Nothing that was refused becomes allowed: an absent project can equal
  # no topic.
  defp confirm_execution_target(project_id, socket) do
    if project_id == Map.get(socket.assigns, :project_id),
      do: :ok,
      else: {:error, :unauthorized_execution_target}
  end

  defp attach(project_id, contract, socket) do
    Transport.attach(project_id, Map.put(contract, :worker_id, socket.assigns.worker_id))
  end

  defp intake(payload, type, tag, socket) do
    case accept(payload, type, socket) do
      {:ok, envelope} ->
        publish(socket, {tag, envelope})
        {:reply, {:ok, %{status: "accepted"}}, socket}

      {:error, reason} ->
        {:reply, {:error, refusal(reason)}, socket}
    end
  end

  # An announcement is not storage. The page a person is watching re-reads the
  # run when this topic carries an event, so an event that was broadcast and
  # never written leaves the reader with nothing to find. Storing first also
  # means a refusal reaches the worker: a superseded attempt hears that its
  # event was not taken instead of hearing silence.
  #
  # Only the event types `EventIngestion` turns into activity are stored here.
  # The others are owned by the modules that give them meaning, so this intake
  # passes them on exactly as it always has rather than refusing what it does
  # not own.
  defp store(envelope, socket) do
    if envelope["event_type"] in EventIngestion.handled_event_types() do
      ingest(envelope, socket)
    else
      :ok
    end
  end

  defp ingest(envelope, socket) do
    project_id = socket.assigns.project_id

    case EventIngestion.ingest(project_authority(project_id), project_id, envelope) do
      {:ok, _stored} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Authority comes from the project, never from the credential, which names an
  # execution target rather than a store. A project that is not a hosted one, or
  # is not there at all, resolves to no authority, and the delivery store refuses
  # that closed without disclosing which of the two it was.
  defp project_authority(project_id) do
    case Repo.get(Project, project_id) do
      %Project{storage_mode: "hosted", workspace_id: workspace_id} ->
        Repo.get(PersonalWorkspace, workspace_id)

      _other ->
        nil
    end
  rescue
    Ecto.Query.CastError -> nil
  end

  defp acknowledge(payload, socket) do
    with {:ok, envelope} <- accept(payload, "acknowledgement", socket),
         {:ok, command} <- scoped_command(envelope["command_id"], socket),
         {:ok, recorded} <- CommandOutbox.acknowledge(command, result(envelope)) do
      {:ok, recorded.state}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      {:error, _rejected} -> {:error, :acknowledgement_rejected}
    end
  end

  # A command belonging to another project is answered exactly like one that
  # does not exist, so a worker cannot probe for work outside its target.
  defp scoped_command(command_id, socket) do
    with {:ok, command} <- CommandOutbox.fetch(command_id),
         true <- command.project_id == socket.assigns.project_id do
      {:ok, command}
    else
      _denied -> {:error, :unknown_command}
    end
  end

  # The outbox replays this to a duplicate enqueue, so it holds the worker's
  # answer and its ordering only — never anything the worker observed.
  defp result(envelope),
    do: Map.take(envelope, ~w(status reason attempt_number fence_token acknowledged_at))

  defp liveness(envelope),
    do: Map.take(envelope, ~w(run_id attempt_number state last_sequence observed_at))

  defp accept(payload, type, socket) do
    case validated(payload, type) do
      {:ok, envelope} -> confirm_reported_target(envelope, socket)
      {:error, _reason} = refusal -> refusal
    end
  end

  # Encoding is what enforces the envelope limit, so an inbound frame is
  # measured by its canonical form rather than by however the peer spelled it.
  defp validated(%{"type" => type} = payload, type) do
    case ProtocolCodec.encode(payload) do
      {:ok, _encoded} -> {:ok, payload}
      {:error, _reason} = refusal -> refusal
    end
  end

  defp validated(_payload, _type), do: {:error, :unexpected_envelope}

  # A heartbeat or snapshot names the execution target it speaks for, and it
  # must be the one this socket authenticated.
  defp confirm_reported_target(%{"worker_id" => worker_id} = envelope, socket) do
    if worker_id == socket.assigns.worker_id,
      do: {:ok, envelope},
      else: {:error, :unauthorized_execution_target}
  end

  defp confirm_reported_target(envelope, _socket), do: {:ok, envelope}

  defp publish(socket, message),
    do: PubSub.broadcast(SddOrchestrator.PubSub, topic(socket.assigns.project_id), message)

  defp refusal(reason) when is_atom(reason), do: %{reason: Atom.to_string(reason)}
  defp refusal(_reason), do: %{reason: "unavailable"}
end
