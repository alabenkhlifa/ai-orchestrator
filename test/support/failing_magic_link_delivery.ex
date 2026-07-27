defmodule SddOrchestrator.FailingMagicLinkDelivery do
  @moduledoc false

  @behaviour SddOrchestrator.HostedAccess.Delivery

  @impl true
  def deliver(_email), do: {:error, :provider_unavailable}
end
