defmodule SddOrchestratorWeb.InitializationWorkerChannel do
  @moduledoc """
  One authenticated worker's pre-project initialization session for one device workspace.

  The socket already authenticated the pairing credential; the joined topic
  must name the same device workspace (re-checked here, so a revocation
  between connect and join is caught), and the capability grants this
  connection may exercise are negotiated before any dispatch is reachable.

  Every dispatch is refused unless its manifest's own capability grant was
  actually negotiated for this connection — the sole enforcement point that
  keeps a read-only session from ever reaching a staging-write operation.
  """
  use Phoenix.Channel

  alias SddOrchestrator.Delivery.InitializationDispatch
  alias SddOrchestrator.Devices.{LocalWorker, Pairing}
  alias SddOrchestrator.Repo

  @doc "The topic naming one device workspace's initialization session."
  @spec topic(Ecto.UUID.t()) :: String.t()
  def topic(device_workspace_id), do: "initialization:#{device_workspace_id}"

  @impl true
  def join("initialization:" <> topic_workspace, params, socket) do
    with {:ok, workspace_id} <- cast_workspace(topic_workspace),
         :ok <- authorize_workspace(workspace_id, socket),
         {:ok, %{capability_grants: granted}} <- InitializationDispatch.negotiate(params) do
      {:ok, %{capability_grants: granted}, assign(socket, :capability_grants, granted)}
    else
      {:error, reason} -> {:error, refusal(reason)}
    end
  end

  def join(_topic, _params, _socket), do: {:error, %{reason: "unknown_topic"}}

  @impl true
  def handle_in("dispatch", payload, socket) when is_map(payload) do
    attrs = Map.put(payload, "device_workspace_id", socket.assigns.device_workspace_id)

    case InitializationDispatch.dispatch(attrs, socket.assigns.capability_grants) do
      {:ok, result} -> {:reply, {:ok, response(result)}, socket}
      {:error, reason} -> {:reply, {:error, refusal(reason)}, socket}
    end
  end

  def handle_in(_event, _payload, socket),
    do: {:reply, {:error, %{reason: "unsupported_message"}}, socket}

  defp cast_workspace(topic_workspace) do
    case Ecto.UUID.cast(topic_workspace) do
      {:ok, workspace_id} -> {:ok, workspace_id}
      :error -> {:error, :unknown_topic}
    end
  end

  # The socket authenticated one paired worker; the topic is where that
  # worker could otherwise reach across workspaces. The worker row is re-read
  # so a revocation between connect and join is also caught.
  defp authorize_workspace(workspace_id, socket) do
    case Repo.get(LocalWorker, socket.assigns.worker_id) do
      %LocalWorker{} = worker -> Pairing.authorize_for_workspace(worker, workspace_id)
      nil -> {:error, :unauthorized}
    end
  end

  # Never the raw handle (an opaque local reference, not wire-safe) and never
  # the dispatched agent_ref/instructions echoed back.
  defp response(result) do
    %{
      dispatch_id: result.manifest.dispatch_id,
      agent_version: result.agent_version,
      thread_start: Atom.to_string(result.thread_start)
    }
  end

  defp refusal(reason) when is_atom(reason), do: %{reason: Atom.to_string(reason)}
end
