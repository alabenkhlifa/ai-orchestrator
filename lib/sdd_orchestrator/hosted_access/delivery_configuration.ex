defmodule SddOrchestrator.HostedAccess.DeliveryConfiguration do
  @moduledoc """
  Production configuration check for the passwordless delivery boundary.

  A deployment may use a custom module implementing `Delivery`, or the shared
  Swoosh boundary backed by a non-local, non-test adapter. Provider credentials
  stay in runtime configuration and are never returned by this module.
  """

  alias SddOrchestrator.HostedAccess.SwooshDelivery
  alias SddOrchestrator.Mailer

  @non_production_adapters [Swoosh.Adapters.Local, Swoosh.Adapters.Test]

  @type t :: %{
          delivery_module: module() | nil,
          mailer_adapter: module() | nil
        }

  @doc "Returns the active delivery boundary and mailer adapter without provider secrets."
  @spec current() :: t()
  def current do
    %{
      delivery_module: Application.get_env(:sdd_orchestrator, :magic_link_delivery),
      mailer_adapter:
        :sdd_orchestrator
        |> Application.get_env(Mailer, [])
        |> Keyword.get(:adapter)
    }
  end

  @doc "Rejects missing boundaries and local or test adapters for public release."
  @spec ensure_production_ready(t()) ::
          :ok | {:error, {:unsafe_delivery_configuration, atom()}}
  def ensure_production_ready(%{delivery_module: delivery_module} = configuration) do
    cond do
      not delivery_module?(delivery_module) ->
        {:error, {:unsafe_delivery_configuration, :invalid_delivery_module}}

      delivery_module == SwooshDelivery ->
        ensure_swoosh_adapter(configuration[:mailer_adapter])

      true ->
        :ok
    end
  end

  def ensure_production_ready(_configuration) do
    {:error, {:unsafe_delivery_configuration, :invalid_delivery_module}}
  end

  defp ensure_swoosh_adapter(adapter) when adapter in @non_production_adapters do
    {:error, {:unsafe_delivery_configuration, :local_or_test_mailer_adapter}}
  end

  defp ensure_swoosh_adapter(adapter) do
    if is_atom(adapter) and Code.ensure_loaded?(adapter) do
      :ok
    else
      {:error, {:unsafe_delivery_configuration, :invalid_mailer_adapter}}
    end
  end

  defp delivery_module?(module) do
    is_atom(module) and Code.ensure_loaded?(module) and function_exported?(module, :deliver, 1)
  end
end
