defmodule SddOrchestrator.Worker.Supervisor do
  @moduledoc """
  The worker's own local supervision tree.

  Loads `SddOrchestrator.Worker.Configuration` before starting any child, so
  a missing or invalid configuration refuses startup with a typed reason
  instead of starting partially. This tree never opens a database connection
  and never calls a control-plane context module, directly or transitively —
  a genuinely remote worker has neither available.
  """

  use Supervisor

  alias SddOrchestrator.Worker.{Configuration, GatewayConnection, State}

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
    children = [
      {State, config},
      {GatewayConnection, config}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

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
