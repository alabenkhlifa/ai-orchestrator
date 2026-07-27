defmodule SddOrchestrator.HostedAccess.Delivery do
  @moduledoc "Delivery boundary for one passwordless authentication email."

  @callback deliver(Swoosh.Email.t()) ::
              {:ok, term()} | {:error, term()}
end
