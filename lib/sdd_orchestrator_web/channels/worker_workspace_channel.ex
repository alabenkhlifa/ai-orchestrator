defmodule SddOrchestratorWeb.WorkerWorkspaceChannel do
  @moduledoc """
  One authenticated worker's attachment session for one Mac.

  The socket already verified a credential naming exactly one device workspace,
  and the joined topic must name the same one. That check runs before the
  capability contract is negotiated, so a join aimed at another Mac is refused
  before it can be told anything and before any attachment is recorded. A
  socket that carries no device workspace at all, such as a project-scoped one,
  matches nothing here and is refused the same way.

  This channel carries no command delivery, no acknowledgements, no events, no
  heartbeats, and no reconciliation. It exists so the control plane knows this
  Mac's worker is live, which is a question every dashboard already asks of a
  worker that has joined no project. It carries exactly two request and answer
  pairs beyond that: a `repository_selection` push asks the worker to open its
  folder picker, and a `repository_selection_result` frame brings back which
  identities matched and the folder's own name. A `repository_metadata` push
  asks the worker to read the repository at a chosen root, and a
  `repository_metadata_result` frame brings back its identity, root, and
  commit. That is not execution. The worker shows a panel and reports
  identities, and anything a worker may actually execute still stays on the
  project-scoped `worker:` topic, where a project-scoped credential is what
  authorizes it.

  It also carries the `project_bound` and `project_unbound` notices, which name
  a project id and nothing else. They are not delivery either. A notice tells
  the worker which projects it now serves so it can open its own project-scoped
  connection for each one, and every run still travels over that connection's
  own topic under its own credential. A worker that attaches while bindings
  already exist is told about all of them at the join, because a binding made
  while nobody was listening would otherwise never be heard.

  The workspace and the worker an answer is credited to are read from this
  socket's own authenticated assigns and never from the frame. An attachment
  can therefore only ever close a request that was pushed to it, and a frame
  naming somebody else's request is refused rather than delivered.

  Unknown inbound messages are therefore refused rather than interpreted. The
  session stays open through a refusal, so one unexpected frame does not cost a
  correct worker its attachment.
  """
  use Phoenix.Channel

  alias SddOrchestrator.Delivery.BoundProjectNotice
  alias SddOrchestrator.Delivery.WorkerAttachment
  alias SddOrchestrator.Delivery.WorkerProtocol
  alias SddOrchestrator.RepositoryMetadata
  alias SddOrchestrator.RepositoryMetadata.AttachmentCodec, as: MetadataAttachmentCodec
  alias SddOrchestrator.RepositorySelection
  alias SddOrchestrator.RepositorySelection.AttachmentCodec

  @impl true
  def join("worker_workspace:" <> device_workspace_id, params, socket) do
    with :ok <- confirm_device_workspace(device_workspace_id, socket),
         {:ok, contract} <- WorkerProtocol.negotiate(params),
         {:ok, _attachment} <- attach(device_workspace_id, contract, socket) do
      # After the attachment is recorded, never before: the notice is sent to
      # whoever is attached for this Mac, and this connection has to be one of
      # them to hear about its own bindings.
      BoundProjectNotice.announce_bound(device_workspace_id)

      {:ok, contract, assign(socket, :contract, contract)}
    else
      {:error, reason} -> {:error, refusal(reason)}
    end
  end

  def join(_topic, _params, _socket), do: {:error, %{reason: "unknown_topic"}}

  @impl true
  def handle_in("repository_selection_result", payload, socket) do
    case answer(payload, socket) do
      :ok -> {:reply, :ok, socket}
      {:error, reason} -> {:reply, {:error, %{reason: to_string(reason)}}, socket}
    end
  end

  def handle_in("repository_metadata_result", payload, socket) do
    case answer_metadata(payload, socket) do
      :ok -> {:reply, :ok, socket}
      {:error, reason} -> {:reply, {:error, %{reason: to_string(reason)}}, socket}
    end
  end

  def handle_in(_event, _payload, socket),
    do: {:reply, {:error, %{reason: "unsupported_message"}}, socket}

  @impl true
  def handle_info({:repository_selection, payload}, socket) do
    push(socket, "repository_selection", payload)
    {:noreply, socket}
  end

  def handle_info({:repository_selection_cancel, payload}, socket) do
    push(socket, "repository_selection_cancel", payload)
    {:noreply, socket}
  end

  def handle_info({:repository_metadata, payload}, socket) do
    push(socket, "repository_metadata", payload)
    {:noreply, socket}
  end

  def handle_info({:repository_metadata_cancel, payload}, socket) do
    push(socket, "repository_metadata_cancel", payload)
    {:noreply, socket}
  end

  def handle_info({:project_bound, payload}, socket) do
    push(socket, "project_bound", payload)
    {:noreply, socket}
  end

  def handle_info({:project_unbound, payload}, socket) do
    push(socket, "project_unbound", payload)
    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # The attachment that answers is the socket, not the frame. Reading the
  # workspace and the worker from the authenticated assigns is what makes a
  # result from another attachment refusable: the request lifecycle compares
  # them against the attachment the push actually went to.
  defp answer(payload, socket) do
    case AttachmentCodec.decode_result(payload) do
      {:ok, attrs} -> RepositorySelection.answer(attachment(socket), attrs)
      {:error, reason} -> {:error, reason}
    end
  end

  defp answer_metadata(payload, socket) do
    case MetadataAttachmentCodec.decode_result(payload) do
      {:ok, attrs} -> RepositoryMetadata.answer(attachment(socket), attrs)
      {:error, reason} -> {:error, reason}
    end
  end

  defp attachment(socket) do
    %{
      device_workspace_id: socket.assigns.device_workspace_id,
      worker_id: socket.assigns.worker_id
    }
  end

  # The socket authenticated one device workspace; the topic is where a worker
  # would otherwise reach across Macs, so it is checked before negotiation and
  # therefore before the control plane records anything about this connection.
  # A socket holding no device workspace matches no topic here, because the
  # value it would be compared against is absent rather than wrong.
  defp confirm_device_workspace(device_workspace_id, socket) do
    if device_workspace_id == Map.get(socket.assigns, :device_workspace_id),
      do: :ok,
      else: {:error, :unauthorized_device_workspace}
  end

  defp attach(device_workspace_id, contract, socket) do
    WorkerAttachment.attach(
      device_workspace_id,
      Map.put(contract, :worker_id, socket.assigns.worker_id)
    )
  end

  defp refusal(reason) when is_atom(reason), do: %{reason: Atom.to_string(reason)}
  defp refusal(_reason), do: %{reason: "unavailable"}
end
