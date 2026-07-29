defmodule SddOrchestrator.CommandTransportDouble do
  @moduledoc """
  A deterministic command transport for tests.

  Records what the dispatcher handed it and replays a scripted outcome, so the
  outbox's claim, lease, replay, and restart behaviour can be proven without a
  connected worker. The script and the recording live in the calling process,
  which keeps concurrent tests from seeing each other's deliveries.
  """
  @behaviour SddOrchestrator.Delivery.CommandTransport

  @outcome_key {__MODULE__, :outcome}
  @delivered_key {__MODULE__, :delivered}

  @doc "Installs this double as the configured transport for one test."
  def install(outcome \\ :ok) do
    original = Application.get_env(:sdd_orchestrator, :command_transport)
    Application.put_env(:sdd_orchestrator, :command_transport, __MODULE__)
    Process.put(@outcome_key, outcome)
    Process.put(@delivered_key, [])

    fn -> Application.put_env(:sdd_orchestrator, :command_transport, original) end
  end

  @doc "Changes the scripted outcome for later deliveries."
  def script(outcome), do: Process.put(@outcome_key, outcome)

  @doc "The commands handed to the transport, oldest first."
  def delivered, do: Process.get(@delivered_key, []) |> Enum.reverse()

  @impl true
  def deliver(command) do
    Process.put(@delivered_key, [command | Process.get(@delivered_key, [])])
    Process.get(@outcome_key, :ok)
  end
end
