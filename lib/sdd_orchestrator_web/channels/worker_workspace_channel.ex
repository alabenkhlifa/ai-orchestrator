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
  worker that has joined no project. Anything a worker may actually execute
  stays on the project-scoped `worker:` topic, where a project-scoped
  credential is what authorizes it.

  Unknown inbound messages are therefore refused rather than interpreted. The
  session stays open through a refusal, so one unexpected frame does not cost a
  correct worker its attachment.
  """
  use Phoenix.Channel

  alias SddOrchestrator.Delivery.WorkerAttachment
  alias SddOrchestrator.Delivery.WorkerProtocol

  @impl true
  def join("worker_workspace:" <> device_workspace_id, params, socket) do
    with :ok <- confirm_device_workspace(device_workspace_id, socket),
         {:ok, contract} <- WorkerProtocol.negotiate(params),
         {:ok, _attachment} <- attach(device_workspace_id, contract, socket) do
      {:ok, contract, assign(socket, :contract, contract)}
    else
      {:error, reason} -> {:error, refusal(reason)}
    end
  end

  def join(_topic, _params, _socket), do: {:error, %{reason: "unknown_topic"}}

  @impl true
  def handle_in(_event, _payload, socket),
    do: {:reply, {:error, %{reason: "unsupported_message"}}, socket}

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
