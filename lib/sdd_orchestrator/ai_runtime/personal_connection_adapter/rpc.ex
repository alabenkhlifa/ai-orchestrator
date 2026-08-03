defmodule SddOrchestrator.AIRuntime.PersonalConnectionAdapter.RPC do
  @moduledoc """
  Production personal-connection adapter over the authenticated worker RPC.

  The wire request and nested result both have exact safe field sets. Provider
  identity and credential material have no representable field in this contract.
  """

  @behaviour SddOrchestrator.AIRuntime.PersonalConnectionAdapter

  alias SddOrchestrator.AIRuntime.{PersonalConnectionAdapter, PersonalWorkerRPC}

  @capability "connection/1"
  @operation "link"

  @impl true
  def link(
        account,
        worker,
        %{provider: provider, authentication_mode: authentication_mode} = request,
        opts
      )
      when is_binary(provider) and is_binary(authentication_mode) do
    rpc = Keyword.get(opts, :rpc, PersonalWorkerRPC)

    params = %{
      "operation" => @operation,
      "provider" => provider,
      "authentication_mode" => authentication_mode
    }

    rpc_opts = Keyword.take(opts, [:timeout_ms, :idempotency_key, :rpc_result, :notify])

    case rpc.request(
           account.id,
           worker.device_workspace_id,
           worker.id,
           @capability,
           params,
           rpc_opts
         ) do
      {:ok, result} -> PersonalConnectionAdapter.validate_result(result, request)
      {:error, reason} -> {:error, PersonalConnectionAdapter.normalize_error(reason)}
      _other -> {:error, :invalid_response}
    end
  end

  def link(_account, _worker, _request, _opts), do: {:error, :invalid_request}
end
