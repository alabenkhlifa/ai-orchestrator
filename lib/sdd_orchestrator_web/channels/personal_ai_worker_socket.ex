defmodule SddOrchestratorWeb.PersonalAIWorkerSocket do
  @moduledoc """
  The paired worker's connection boundary for personal AI operations.

  A paired local worker dials the control plane and presents the per-worker
  pairing credential it received exactly once at pairing time — the credential
  is the authentication, so no second token scheme exists on this transport.
  Only an active paired worker connects; a revoked or rotated-away credential
  is refused before any channel is reachable.

  The connection is scoped to the one device workspace the pairing authorized.
  This socket is deliberately separate from the Slice 07 run gateway: nothing
  authenticated here can address a project or a run.
  """
  use Phoenix.Socket

  alias SddOrchestrator.Devices.Pairing

  channel "personal_ai:*", SddOrchestratorWeb.PersonalAIWorkerChannel

  @impl true
  def connect(%{"credential" => credential}, socket, _connect_info) do
    case Pairing.authenticate_worker(credential) do
      {:ok, worker} ->
        {:ok,
         socket
         |> assign(:worker_id, worker.id)
         |> assign(:device_workspace_id, worker.device_workspace_id)}

      {:error, :unauthorized} ->
        :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  # Identifying the socket by its workspace and worker is what lets the
  # control plane disconnect one worker's personal AI sessions without
  # touching another's.
  @impl true
  def id(socket),
    do:
      "personal_ai_worker_socket:#{socket.assigns.device_workspace_id}:#{socket.assigns.worker_id}"
end
