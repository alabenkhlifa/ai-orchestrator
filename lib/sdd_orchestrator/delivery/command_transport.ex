defmodule SddOrchestrator.Delivery.CommandTransport do
  @moduledoc """
  How a claimed command reaches the configured worker.

  The outbox and dispatcher own durability and exclusivity; this boundary owns
  only the hand-off. Keeping them apart is what lets the queue be proven
  without a worker, and lets the worker gateway be replaced without touching
  claim, lease, or replay semantics.

  `deliver/1` reports whether the command left the control plane, never whether
  the work succeeded. A worker reports the outcome later through its own
  acknowledgement, which is what the outbox records for replay.
  """

  alias SddOrchestrator.Delivery.RunCommand

  @type reason :: :no_worker | :incompatible_worker | :transport_error

  @callback deliver(RunCommand.t()) :: :ok | {:error, reason()}

  @doc "The configured transport, defaulting to the unavailable-worker stand-in."
  @spec transport() :: module()
  def transport do
    Application.get_env(
      :sdd_orchestrator,
      :command_transport,
      SddOrchestrator.Delivery.CommandTransport.Unavailable
    )
  end

  @doc "Delivers one command through the configured transport."
  @spec deliver(RunCommand.t()) :: :ok | {:error, reason()}
  def deliver(%RunCommand{} = command), do: transport().deliver(command)
end

defmodule SddOrchestrator.Delivery.CommandTransport.Unavailable do
  @moduledoc """
  The default transport: no worker is connected.

  A command stays queued and due rather than being lost or failed, which is the
  correct behaviour before the worker gateway exists and whenever no compatible
  worker is currently attached.
  """
  @behaviour SddOrchestrator.Delivery.CommandTransport

  @impl true
  def deliver(_command), do: {:error, :no_worker}
end
