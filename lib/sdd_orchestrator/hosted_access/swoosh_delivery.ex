defmodule SddOrchestrator.HostedAccess.SwooshDelivery do
  @moduledoc "Swoosh-backed passwordless email delivery."

  @behaviour SddOrchestrator.HostedAccess.Delivery

  @impl true
  def deliver(email), do: SddOrchestrator.Mailer.deliver(email)
end
