defmodule SddOrchestrator.ParticipationDeliveryDouble do
  @moduledoc false

  @behaviour SddOrchestrator.HostedAccess.Delivery

  @doc "Routes delivery to the calling test so sent messages can be inspected."
  @impl true
  def deliver(email) do
    case Process.get(:participation_delivery_outcome, :ok) do
      :ok ->
        send(self(), {:participation_email, email})
        {:ok, %{id: "double"}}

      :error ->
        {:error, :provider_unavailable}

      :raise ->
        raise "provider exploded"
    end
  end

  @doc "Makes the next deliveries in this process fail or raise."
  def fail_next(outcome \\ :error), do: Process.put(:participation_delivery_outcome, outcome)

  @doc "Restores successful delivery for this process."
  def succeed, do: Process.put(:participation_delivery_outcome, :ok)
end
