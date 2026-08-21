defmodule SddOrchestrator.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  alias SddOrchestrator.Worker.Configuration
  alias SddOrchestrator.Worker.Supervisor, as: WorkerSupervisor

  # Set by `rel/overlays/worker/env.sh.eex` before the `:worker` release's
  # `bin/worker start` boots the VM (see `mix.exs`'s `releases/0`). Absent
  # for the control-plane release and for every other invocation
  # (`mix phx.server`, `mix test`, the default `mix release`), all of which
  # boot the full control-plane tree exactly as before.
  @release_mode_env "SDD_ORCHESTRATOR_RELEASE_MODE"
  @worker_release_mode "worker"

  # The worker's always-up host: a `DynamicSupervisor` that can start with
  # zero configuration present, because `SddOrchestrator.Worker.Supervisor`
  # itself refuses to start until a configuration has been paired (see its
  # `@moduledoc`). specs/36 Task 4's pairing handoff calls
  # `DynamicSupervisor.start_child(SddOrchestrator.Application.worker_host_name(),
  # SddOrchestrator.Worker.Supervisor)` once pairing succeeds; this module
  # uses the same registered name to attach an already-paired configuration
  # on relaunch, in `attach_paired_worker/1` below.
  @worker_host_name SddOrchestrator.Worker.Host

  @doc "The registered name of the worker-mode `DynamicSupervisor` host."
  @spec worker_host_name() :: atom()
  def worker_host_name, do: @worker_host_name

  @impl true
  def start(_type, _args) do
    case boot_mode() do
      :worker -> start_worker_mode()
      :control_plane -> start_control_plane()
    end
  end

  @doc "Reads the release-mode boot gate. See `@release_mode_env` above."
  @spec boot_mode() :: :worker | :control_plane
  def boot_mode do
    if System.get_env(@release_mode_env) == @worker_release_mode do
      :worker
    else
      :control_plane
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    SddOrchestratorWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # --- Worker mode ---------------------------------------------------------
  #
  # Never starts `SddOrchestratorWeb.Endpoint`, `SddOrchestrator.Repo`,
  # `SddOrchestrator.Vault`, or any control-plane rate-limiter/dispatcher/
  # retention/device-store child — a genuinely remote worker has none of
  # those available. `Worker.Supervisor` refuses to start without a paired
  # configuration, so it is never a static child of the top-level
  # supervisor: a first launch, before the operator has ever paired, must
  # still boot successfully so a later menu-bar UI (specs/36 Task 2) can
  # show "not paired" and receive a pairing deep link (specs/36 Task 4).

  defp start_worker_mode do
    opts = [strategy: :one_for_one, name: SddOrchestrator.Supervisor]

    with {:ok, pid} <- Supervisor.start_link(worker_mode_children(), opts) do
      attach_paired_worker(worker_host_name())
      {:ok, pid}
    end
  end

  @doc """
  The worker-mode top-level children list: only the always-up
  `DynamicSupervisor` host, registered as `worker_host_name/0`. Starts
  successfully with zero configuration present.
  """
  @spec worker_mode_children() :: [{module(), keyword()}]
  def worker_mode_children do
    [{DynamicSupervisor, name: worker_host_name(), strategy: :one_for_one}]
  end

  @doc """
  Starts `SddOrchestrator.Worker.Supervisor` under `host` when a worker
  configuration is already stored (a relaunch after a previous pairing).
  Leaves `host` empty when no configuration has ever been paired — the
  later pairing flow starts it the same way, by calling
  `DynamicSupervisor.start_child(host, SddOrchestrator.Worker.Supervisor)`
  directly once pairing completes.
  """
  @spec attach_paired_worker(Supervisor.supervisor()) :: DynamicSupervisor.on_start_child() | :ok
  def attach_paired_worker(host) do
    case Configuration.load(nil) do
      {:ok, _config} -> DynamicSupervisor.start_child(host, WorkerSupervisor)
      {:error, _reason} -> :ok
    end
  end

  # --- Control-plane mode ---------------------------------------------------

  defp start_control_plane do
    opts = [strategy: :one_for_one, name: SddOrchestrator.Supervisor]
    Supervisor.start_link(control_plane_children(), opts)
  end

  defp control_plane_children do
    [
      SddOrchestratorWeb.Telemetry,
      SddOrchestrator.Vault,
      SddOrchestrator.Repo,
      SddOrchestrator.HostedAccess.RateLimiter,
      {DNSCluster, query: Application.get_env(:sdd_orchestrator, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: SddOrchestrator.PubSub},
      # Attached workers are looked up, never dialled. Losing every
      # registration on restart is correct: each worker reconnects, and the
      # command queue was never in this process anyway.
      {Registry,
       keys: :duplicate, name: SddOrchestrator.Delivery.CommandTransport.Channel.registry()},
      # One live personal AI connection per paired worker. Unique keys make
      # a reconnect an explicit replacement of the stale channel rather than
      # a second route; losing registrations on restart is correct because
      # every worker reconnects and re-registers.
      {Registry, keys: :unique, name: SddOrchestrator.AIRuntime.PersonalWorkerRPC.registry()}
    ] ++
      retention_children() ++
      dispatcher_children() ++
      device_store_children() ++
      [
        # Start to serve requests, typically the last entry
        SddOrchestratorWeb.Endpoint
      ]
  end

  # The hourly retention pruner runs in dev and prod; the test environment drives
  # SddOrchestrator.Privacy.Retention directly instead of on a timer.
  defp retention_children do
    if Application.get_env(:sdd_orchestrator, :start_retention_pruner, true) do
      [SddOrchestrator.Privacy.RetentionPruner]
    else
      []
    end
  end

  # The command dispatcher drains the durable outbox in dev and prod. Tests
  # drive SddOrchestrator.Delivery.Dispatcher.dispatch_now/1 directly so a timer
  # never races the Ecto sandbox.
  defp dispatcher_children do
    if Application.get_env(:sdd_orchestrator, :start_command_dispatcher, true) do
      [SddOrchestrator.Delivery.Dispatcher]
    else
      []
    end
  end

  # The durable local DeviceStore stands in for the native worker in development.
  # Tests start their own isolated instance; production uses the release-gated
  # native worker adapter.
  defp device_store_children do
    config = Application.get_env(:sdd_orchestrator, SddOrchestrator.Devices.DeviceStore.Local, [])

    if config[:start] do
      [{SddOrchestrator.Devices.DeviceStore.Local, config}]
    else
      []
    end
  end
end
