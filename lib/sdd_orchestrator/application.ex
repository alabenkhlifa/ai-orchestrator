defmodule SddOrchestrator.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        SddOrchestratorWeb.Telemetry,
        SddOrchestrator.Vault,
        SddOrchestrator.Repo,
        SddOrchestrator.HostedAccess.RateLimiter,
        {DNSCluster,
         query: Application.get_env(:sdd_orchestrator, :dns_cluster_query) || :ignore},
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

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: SddOrchestrator.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    SddOrchestratorWeb.Endpoint.config_change(changed, removed)
    :ok
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
