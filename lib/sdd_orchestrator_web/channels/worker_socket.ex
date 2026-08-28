defmodule SddOrchestratorWeb.WorkerSocket do
  @moduledoc """
  The worker-initiated connection boundary for one execution target.

  A configured worker dials the control plane; the control plane never dials a
  worker, so a local or user-managed worker exposes no inbound port. The signed
  token presented here names exactly one scope and one execution target, and it
  authorizes nothing beyond them.

  Two scopes exist because a worker is authorized for its Mac before it is
  authorized for any project:

    * a project-scoped credential names one project, and the channel re-checks
      that project on every join, so a valid token for one project can never
      reach another;
    * a workspace-scoped credential names only the device workspace the pairing
      proved, and carries no project at all. A worker paired from the menu bar
      has no project yet, so this is the only credential it can hold.

  The two claim shapes carry disjoint keys and are verified under separate
  clauses, so neither can ever be read as the other: a workspace-scoped token
  can never satisfy a project-scoped check, and a project-scoped token can never
  stand in for the workspace one. Widening one scope therefore cannot widen the
  other by accident.

  Provisioning and rotation of these credentials belong to the worker-setup
  workflow outside this slice. The bounded lifetime enforced here is what keeps
  a leaked token from being usable indefinitely.
  """
  use Phoenix.Socket

  alias SddOrchestrator.Delivery.WorkerProtocol
  alias SddOrchestratorWeb.Endpoint

  @signing_salt "worker-gateway-v1"
  @max_age_seconds 24 * 60 * 60

  channel "worker:*", SddOrchestratorWeb.WorkerChannel
  channel "worker_workspace:*", SddOrchestratorWeb.WorkerWorkspaceChannel

  @type project_claims :: %{project_id: Ecto.UUID.t(), worker_id: String.t()}
  @type workspace_claims :: %{device_workspace_id: Ecto.UUID.t(), worker_id: String.t()}
  @type claims :: project_claims() | workspace_claims()
  @type scope :: Ecto.UUID.t() | {:device_workspace, Ecto.UUID.t()}

  @doc """
  Signs one worker credential for a single scope and execution target.

  A bare project id is the project scope. It keeps the call shape every existing
  caller already uses, so the project-scoped claim it produces is unchanged.
  `{:device_workspace, id}` asks instead for the workspace-scoped credential a
  worker with no project can still hold; naming the scope explicitly is what
  stops a caller from producing one shape while meaning the other.
  """
  @spec issue(scope(), String.t(), keyword()) :: String.t()
  def issue(scope, worker_id, opts \\ [])

  def issue({:device_workspace, device_workspace_id}, worker_id, opts) do
    sign(%{device_workspace_id: device_workspace_id, worker_id: worker_id}, opts)
  end

  def issue(project_id, worker_id, opts) when is_binary(project_id) do
    sign(%{project_id: project_id, worker_id: worker_id}, opts)
  end

  @doc """
  Returns the scope an untampered, unexpired credential names.

  Both scopes share one signing salt and one bounded lifetime, so neither can
  outlive or out-trust the other. The `map_size/1` guards are what keep them
  apart: a claim carrying both a project and a device workspace matches neither
  shape and is refused, so a token can never be read under a scope it was not
  signed for.
  """
  @spec verify(term()) :: {:ok, claims()} | :error
  def verify(token) when is_binary(token) do
    case Phoenix.Token.verify(Endpoint, @signing_salt, token, max_age: @max_age_seconds) do
      {:ok, %{project_id: project_id, worker_id: worker_id} = claims}
      when map_size(claims) == 2 ->
        confirm(%{project_id: project_id, worker_id: worker_id})

      {:ok, %{device_workspace_id: device_workspace_id, worker_id: worker_id} = claims}
      when map_size(claims) == 2 ->
        confirm(%{device_workspace_id: device_workspace_id, worker_id: worker_id})

      _rejected ->
        :error
    end
  end

  def verify(_token), do: :error

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    case verify(token) do
      {:ok, %{project_id: project_id, worker_id: worker_id}} ->
        {:ok, socket |> assign(:project_id, project_id) |> assign(:worker_id, worker_id)}

      # A workspace-scoped credential authorizes a Mac, not a project, so the
      # socket it opens carries no project at all. Nothing downstream can then
      # mistake it for one: the Mac-scoped topic is the only thing this socket
      # can be checked against, and the project channel finds nothing to match.
      {:ok, %{device_workspace_id: device_workspace_id, worker_id: worker_id}} ->
        {:ok,
         socket
         |> assign(:device_workspace_id, device_workspace_id)
         |> assign(:worker_id, worker_id)}

      _refused ->
        :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  # Identifying the socket by its execution target is what lets the control
  # plane disconnect one worker's sessions without touching another's. The two
  # scopes are identified in separate spaces: a valid id can never contain the
  # `:` that separates them, so a project id can never spell a workspace one.
  @impl true
  def id(%{assigns: %{project_id: project_id, worker_id: worker_id}}),
    do: "worker_socket:#{project_id}:#{worker_id}"

  def id(%{assigns: %{device_workspace_id: device_workspace_id, worker_id: worker_id}}),
    do: "worker_socket:workspace:#{device_workspace_id}:#{worker_id}"

  defp sign(claims, opts), do: Phoenix.Token.sign(Endpoint, @signing_salt, claims, opts)

  # Every id crossing this boundary is re-checked against the shared protocol
  # format, so a correctly signed but malformed claim is refused here rather
  # than carried on into a topic name or a lookup key.
  defp confirm(claims) do
    if Enum.all?(Map.values(claims), &WorkerProtocol.valid_id?/1) do
      {:ok, claims}
    else
      :error
    end
  end
end
