defmodule SddOrchestratorWeb.WorkerSocket do
  @moduledoc """
  The worker-initiated connection boundary for one execution target.

  A configured worker dials the control plane; the control plane never dials a
  worker, so a local or user-managed worker exposes no inbound port. The signed
  token presented here names exactly one project and one execution target, and
  it authorizes nothing beyond them — the channel re-checks the project on
  every join, so a valid token for one project can never reach another.

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

  @type claims :: %{project_id: Ecto.UUID.t(), worker_id: String.t()}

  @doc "Signs one worker credential for a single project and execution target."
  @spec issue(Ecto.UUID.t(), String.t(), keyword()) :: String.t()
  def issue(project_id, worker_id, opts \\ []) do
    Phoenix.Token.sign(
      Endpoint,
      @signing_salt,
      %{project_id: project_id, worker_id: worker_id},
      opts
    )
  end

  @doc "Returns the execution target an untampered, unexpired credential names."
  @spec verify(term()) :: {:ok, claims()} | :error
  def verify(token) when is_binary(token) do
    case Phoenix.Token.verify(Endpoint, @signing_salt, token, max_age: @max_age_seconds) do
      {:ok, %{project_id: project_id, worker_id: worker_id}} ->
        confirm_claims(project_id, worker_id)

      _rejected ->
        :error
    end
  end

  def verify(_token), do: :error

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    case verify(token) do
      {:ok, claims} ->
        {:ok,
         socket |> assign(:project_id, claims.project_id) |> assign(:worker_id, claims.worker_id)}

      :error ->
        :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  # Identifying the socket by its execution target is what lets the control
  # plane disconnect one worker's sessions without touching another's.
  @impl true
  def id(socket), do: "worker_socket:#{socket.assigns.project_id}:#{socket.assigns.worker_id}"

  defp confirm_claims(project_id, worker_id) do
    if WorkerProtocol.valid_id?(project_id) and WorkerProtocol.valid_id?(worker_id) do
      {:ok, %{project_id: project_id, worker_id: worker_id}}
    else
      :error
    end
  end
end
