defmodule SddOrchestrator.AIRuntime.ObservationAdapter.RPC do
  @moduledoc """
  Production observation adapter over the authenticated personal-worker RPC.

  The request names the consumer whose operational state is being observed and
  the worker-local profile the personal worker must use. The opaque profile
  reference stays inside the scoped request; it is never part of the validated
  observation and never reaches storage.
  """

  @behaviour SddOrchestrator.AIRuntime.ObservationAdapter

  alias SddOrchestrator.AIRuntime.{ObservationAdapter, PersonalWorkerRPC}

  @capability "observation/1"
  @operation "observe"
  @consumers [:support_assistant, :working_agent]

  @impl true
  def observe(account, connection, opts)
      when is_binary(account.id) and is_binary(connection.worker_id) and
             is_binary(connection.worker_profile_ref) do
    with {:ok, consumer} <- consumer(Keyword.get(opts, :consumer)),
         {:ok, consumer_ref} <- consumer_ref(Keyword.get(opts, :consumer_ref)) do
      request(account, connection, consumer, consumer_ref, opts)
    end
  end

  def observe(_account, _connection, _opts), do: {:error, :invalid_request}

  defp request(account, connection, consumer, consumer_ref, opts) do
    rpc = Keyword.get(opts, :rpc, PersonalWorkerRPC)

    params = %{
      "operation" => @operation,
      "connection_ref" => connection.worker_profile_ref,
      "provider" => connection.provider,
      "authentication_mode" => connection.authentication_mode,
      "consumer" => consumer,
      "consumer_ref" => consumer_ref
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
      {:ok, result} -> ObservationAdapter.validate_result(result, connection.provider)
      {:error, reason} -> {:error, ObservationAdapter.normalize_error(reason)}
      _other -> {:error, :invalid_response}
    end
  end

  defp consumer(consumer) when consumer in @consumers, do: {:ok, Atom.to_string(consumer)}
  defp consumer(_consumer), do: {:error, :invalid_request}

  defp consumer_ref(consumer_ref) when is_binary(consumer_ref) do
    if consumer_ref == String.trim(consumer_ref) and byte_size(consumer_ref) in 1..255,
      do: {:ok, consumer_ref},
      else: {:error, :invalid_request}
  end

  defp consumer_ref(_consumer_ref), do: {:error, :invalid_request}
end
