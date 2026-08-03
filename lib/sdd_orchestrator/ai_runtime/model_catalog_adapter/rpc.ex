defmodule SddOrchestrator.AIRuntime.ModelCatalogAdapter.RPC do
  @moduledoc """
  Production catalog adapter over the authenticated personal-worker RPC.

  The opaque worker-local connection reference is used only inside the scoped
  command. It is never returned in the validated catalog or safe projection.
  """

  @behaviour SddOrchestrator.AIRuntime.ModelCatalogAdapter

  alias SddOrchestrator.AIRuntime.{ModelCatalogAdapter, PersonalWorkerRPC}

  @capability "catalog/1"
  @operation "refresh"

  @impl true
  def fetch(account, connection, opts)
      when is_binary(account.id) and is_binary(connection.worker_id) and
             is_binary(connection.worker_profile_ref) do
    rpc = Keyword.get(opts, :rpc, PersonalWorkerRPC)

    params = %{
      "operation" => @operation,
      "connection_ref" => connection.worker_profile_ref,
      "provider" => connection.provider
    }

    rpc_opts = Keyword.take(opts, [:timeout_ms, :idempotency_key, :rpc_result, :notify])

    case rpc.request(
           account.id,
           connection.worker.device_workspace_id,
           connection.worker_id,
           @capability,
           params,
           rpc_opts
         ) do
      {:ok, result} -> ModelCatalogAdapter.validate_result(result, connection.provider)
      {:error, reason} -> {:error, ModelCatalogAdapter.normalize_error(reason)}
      _other -> {:error, :invalid_response}
    end
  end

  def fetch(_account, _connection, _opts), do: {:error, :invalid_request}
end
