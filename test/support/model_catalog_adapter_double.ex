defmodule SddOrchestrator.ModelCatalogAdapterDouble do
  @moduledoc """
  Deterministic test boundary for catalog adapters and catalog RPC calls.

  Every result is supplied by the owning test process; the double keeps no
  catalog or provider state of its own.
  """

  @behaviour SddOrchestrator.AIRuntime.ModelCatalogAdapter

  @impl true
  def fetch(account, connection, opts) do
    notify(opts, {:catalog_fetch, account, connection})
    Keyword.get(opts, :adapter_result, {:error, :worker_unavailable})
  end

  @doc "Implements the six-argument personal-worker RPC seam."
  def request(account_id, device_workspace_id, worker_id, capability, params, opts) do
    notify(
      opts,
      {:catalog_rpc_request, account_id, device_workspace_id, worker_id, capability, params}
    )

    Keyword.get(opts, :rpc_result, {:error, :worker_unavailable})
  end

  defp notify(opts, message) do
    case Keyword.get(opts, :notify) do
      pid when is_pid(pid) -> send(pid, message)
      _other -> :ok
    end
  end
end
