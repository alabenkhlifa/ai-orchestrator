defmodule SddOrchestrator.AIRuntime.PersonalConnectionAdapter.RPC do
  @moduledoc """
  Production personal-connection adapter over the authenticated worker RPC.

  The wire request and nested result both have exact safe field sets. Provider
  identity and credential material have no representable field in this contract.

  Both operations travel on the same already authenticated `connection/1`
  capability, so revoking a worker-local credential needs no second transport
  and no widened protocol vocabulary.
  """

  @behaviour SddOrchestrator.AIRuntime.PersonalConnectionAdapter

  alias SddOrchestrator.AIRuntime.{PersonalConnectionAdapter, PersonalWorkerRPC}

  @capability "connection/1"
  @operation "link"
  @revoke_operation "revoke"
  @rpc_option_keys [:timeout_ms, :idempotency_key, :rpc_result, :notify]

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

    rpc_opts = Keyword.take(opts, @rpc_option_keys)

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

  @impl true
  def revoke(account, worker, %{worker_profile_ref: worker_profile_ref} = request, opts)
      when is_binary(worker_profile_ref) do
    rpc = Keyword.get(opts, :rpc, PersonalWorkerRPC)

    params = %{
      "operation" => @revoke_operation,
      "worker_profile_ref" => worker_profile_ref
    }

    rpc_opts = Keyword.take(opts, @rpc_option_keys)

    case rpc.request(
           account.id,
           worker.device_workspace_id,
           worker.id,
           @capability,
           params,
           rpc_opts
         ) do
      {:ok, result} -> PersonalConnectionAdapter.validate_revocation_result(result, request)
      {:error, reason} -> {:error, PersonalConnectionAdapter.normalize_error(reason)}
      _other -> {:error, :invalid_response}
    end
  end

  def revoke(_account, _worker, _request, _opts), do: {:error, :invalid_request}
end
