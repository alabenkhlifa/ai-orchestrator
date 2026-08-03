defmodule SddOrchestrator.AIRuntime.QuotaAdapter.RPC do
  @moduledoc """
  Production quota adapter over the authenticated personal-worker RPC.

  The opaque worker-local profile reference is used only inside the scoped
  request. It is never returned in the validated quota result or owner view.
  """

  @behaviour SddOrchestrator.AIRuntime.QuotaAdapter

  alias SddOrchestrator.AIRuntime.{PersonalWorkerRPC, QuotaAdapter}

  @capability "quota/1"
  @operation "refresh"

  @impl true
  def fetch(account, connection, opts)
      when is_binary(account.id) and is_binary(connection.worker_id) and
             is_binary(connection.worker_profile_ref) do
    rpc = Keyword.get(opts, :rpc, PersonalWorkerRPC)

    params = %{
      "operation" => @operation,
      "connection_ref" => connection.worker_profile_ref,
      "provider" => connection.provider,
      "authentication_mode" => connection.authentication_mode
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
      {:ok, result} ->
        QuotaAdapter.validate_result(
          result,
          connection.provider,
          connection.authentication_mode
        )

      {:error, reason} ->
        {:error, QuotaAdapter.normalize_error(reason)}

      _other ->
        {:error, :invalid_response}
    end
  end

  def fetch(_account, _connection, _opts), do: {:error, :invalid_request}
end
