defmodule SddOrchestrator.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      SddOrchestratorWeb.Telemetry,
      SddOrchestrator.Vault,
      SddOrchestrator.Repo,
      {DNSCluster, query: Application.get_env(:sdd_orchestrator, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: SddOrchestrator.PubSub},
      # Start a worker by calling: SddOrchestrator.Worker.start_link(arg)
      # {SddOrchestrator.Worker, arg},
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
end
