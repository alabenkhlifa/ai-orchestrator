defmodule SddOrchestrator.Worker.ProjectConnections do
  @moduledoc """
  Holds one gateway connection per project this worker has been told to serve.

  A worker paired from the menu bar dials the control plane for its Mac. That
  socket names no project, and the project topic authorizes from the socket's
  own credential, so the Mac connection can never carry a project's run no
  matter what it asks for. The worker therefore opens a second connection for
  each project it is bound to. That connection asks for the project-scoped
  credential and joins the project topic exactly as a worker configured with a
  project already does, so the connect, the join, the registry, and command
  handling are all the ones already in use. Only the number of connections is
  new.

  Children are keyed by project id and started as temporary. A connection that
  stops has either been refused its credential or lost its project, and reviving
  it here would retry a refusal forever. The Mac connection remembers what it
  opened, so a later `project_bound` notice opens it again.

  Named by default, because a running worker has one of these. The name is still
  a parameter so a test can run its own tree without colliding with another.
  """

  use DynamicSupervisor

  alias SddOrchestrator.Worker.Configuration
  alias SddOrchestrator.Worker.GatewayConnection

  @doc "Starts the supervisor that holds this worker's project connections."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(:ok), do: DynamicSupervisor.init(strategy: :one_for_one)

  @doc """
  Opens one project-scoped connection from a configuration that names a project.

  A supervisor that is not running is reported as a refusal rather than allowed
  to exit the caller. The Mac connection is the caller, and losing it would cost
  the worker every project it serves as well as the one that failed. The exit
  itself is deliberately not carried into the refusal: it quotes the call that
  failed, and that call holds the worker's own configuration, credential
  included.
  """
  @spec open(GenServer.server(), Configuration.t(), keyword()) ::
          DynamicSupervisor.on_start_child()
  def open(supervisor, %Configuration{project_id: project_id} = config, opts)
      when is_binary(project_id) do
    DynamicSupervisor.start_child(supervisor, %{
      id: project_id,
      start: {GatewayConnection, :start_link, [config, opts]},
      restart: :temporary,
      type: :worker
    })
  catch
    :exit, _reason -> {:error, :project_connections_unavailable}
  end

  @doc "Stops one open project connection. A connection already gone is not an error."
  @spec close(GenServer.server(), pid()) :: :ok
  def close(supervisor, pid) when is_pid(pid) do
    DynamicSupervisor.terminate_child(supervisor, pid)
    :ok
  catch
    :exit, _reason -> :ok
  end
end
