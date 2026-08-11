defmodule SddOrchestratorWeb.InitializationWorkerSocket do
  @moduledoc """
  The paired worker's connection boundary for pre-project initialization dispatch.

  A paired local worker dials the control plane and presents the per-worker
  pairing credential it received exactly once at pairing time — the
  credential is the authentication, so no second token scheme exists on this
  transport, and no project-scoped gateway credential is exchanged: a single
  ephemeral dispatch session has no reconnect-over-time lifetime to protect.

  The connection is scoped to the one device workspace the pairing
  authorized. This socket is deliberately separate from the Slice 07 run
  gateway (`/worker`, project-scoped) and from `/personal_ai_worker`
  (account-level AI operations): nothing authenticated here can address a
  project or a run, and the capability grant it may exercise — read-only
  plan discovery, or staging-write — is negotiated per connection at join,
  never assumed.
  """
  use Phoenix.Socket

  alias SddOrchestrator.Devices.Pairing

  channel "initialization:*", SddOrchestratorWeb.InitializationWorkerChannel

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
  # control plane disconnect one worker's initialization sessions without
  # touching another's.
  @impl true
  def id(socket),
    do:
      "initialization_worker_socket:#{socket.assigns.device_workspace_id}:#{socket.assigns.worker_id}"
end
