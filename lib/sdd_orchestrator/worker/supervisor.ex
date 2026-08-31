defmodule SddOrchestrator.Worker.Supervisor do
  @moduledoc """
  The worker's own local supervision tree.

  Loads `SddOrchestrator.Worker.Configuration` before starting any child, so
  a missing or invalid configuration refuses startup with a typed reason
  instead of starting partially. This tree never opens a database connection
  and never calls a control-plane context module, directly or transitively —
  a genuinely remote worker has neither available.

  A configuration with no project is valid (see
  `SddOrchestrator.Worker.Configuration`) and starts the same children as one
  naming a project. `SddOrchestrator.Worker.GatewayConnection` decides which
  scope to dial from the configuration it is given, so a worker authorized for
  its Mac alone connects for that Mac rather than not connecting at all.
  """

  use Supervisor

  alias SddOrchestrator.Delivery.AgentAdapter

  alias SddOrchestrator.Worker.{
    Configuration,
    GatewayConnection,
    ProjectConnections,
    RepositorySelection,
    State
  }

  # `Configuration.agent_adapters/0` is the validated set of strings a paired
  # configuration may carry; anything else is unreachable through pairing but
  # still falls back to the safe default rather than crashing startup.
  @agent_adapter_modules %{
    "claude_code" => AgentAdapter.ClaudeCode,
    "codex" => AgentAdapter.Codex
  }

  @doc """
  Loads the worker configuration (via `opts[:home]`, see
  `SddOrchestrator.Worker.Configuration.home/1`) and, only if it is valid,
  starts the supervision tree. Returns `{:error, reason}` without starting
  any process when the configuration is missing or invalid.
  """
  @spec start_link(keyword()) :: Supervisor.on_start() | {:error, term()}
  def start_link(opts \\ []) do
    home_override = Keyword.get(opts, :home)

    case Configuration.load(home_override) do
      {:ok, config} ->
        sup_opts =
          case Keyword.fetch(opts, :name) do
            {:ok, name} -> [name: name]
            :error -> []
          end

        Supervisor.start_link(__MODULE__, config, sup_opts)

      {:error, _reason} = error ->
        error
    end
  end

  @impl true
  def init(%Configuration{} = config) do
    # The only place that connects the paired configuration's workspace root
    # to `Delivery.Worker.Workspace.root/0`, which reads it from application
    # env rather than a passed-in value — set once, before anything that
    # might prepare a run workspace starts.
    put_workspace_root(config.workspace_root)

    # The only place that turns the paired `agent_adapter`/`agent_executable`
    # strings into what `AgentAdapter.adapter/0` and each adapter's own
    # `executable/0` actually read — set once, before the gateway connection
    # (and therefore any command) can reach an adapter at all.
    Application.put_env(
      :sdd_orchestrator,
      :agent_adapter,
      Map.get(@agent_adapter_modules, config.agent_adapter, AgentAdapter.Unavailable)
    )

    Application.put_env(:sdd_orchestrator, :agent_executable, config.agent_executable)

    Supervisor.init(children(config), strategy: :one_for_one)
  end

  # A worker authorized for its Mac alone has no repository folder yet. The key
  # is cleared rather than set to `nil` so `Workspace.root/0` is answering "no
  # root was configured" — and so a root left behind by an earlier
  # configuration can never point this worker's runs at a folder it was never
  # given.
  defp put_workspace_root(nil),
    do: Application.delete_env(:sdd_orchestrator, :worker_workspace_root)

  defp put_workspace_root(workspace_root),
    do: Application.put_env(:sdd_orchestrator, :worker_workspace_root, workspace_root)

  # Both scopes start the same children. `GatewayConnection` reads the scope off
  # the configuration and joins either the project topic or the Mac-scoped one,
  # so there is no longer a configuration it cannot dial. Withholding it from a
  # projectless worker is what left a genuinely paired worker connected to
  # nothing, which is the defect specs/39-mac-scoped-worker-connection exists to
  # close.
  # `RepositorySelection` holds the one open folder-picker request and publishes
  # it for the Mac app to answer (specs/40-worker-repository-selection Task 3).
  # It starts before the gateway connection, so a request arriving on the first
  # join always has somewhere to land.
  # `ProjectConnections` holds one connection per project this worker is told to
  # serve (specs/41-feature-delivery-from-the-ui Task 7), and starts before the
  # gateway connection for the same reason: a `project_bound` notice arriving on
  # the first join has somewhere to open. Both scopes start it, so the tree has
  # one shape; a worker already configured with a project simply opens nothing
  # under it.
  defp children(%Configuration{} = config),
    do: [
      {State, config},
      {RepositorySelection, []},
      {ProjectConnections, []},
      {GatewayConnection, config}
    ]

  @doc "Reads the configuration held by a running worker's `SddOrchestrator.Worker.State` child."
  @spec configuration(pid()) :: Configuration.t() | nil
  def configuration(supervisor_pid) do
    supervisor_pid
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {State, state_pid, _type, _modules} when is_pid(state_pid) -> State.current(state_pid)
      _other -> nil
    end)
  end
end
