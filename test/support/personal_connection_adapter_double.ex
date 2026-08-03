defmodule SddOrchestrator.PersonalConnectionAdapterDouble do
  @moduledoc """
  Deterministic test boundary for personal-connection adapters and worker RPC.

  Tests explicitly provide a safe result or typed failure. Calls can be sent to
  the owning test process without retaining global state.
  """

  @behaviour SddOrchestrator.AIRuntime.PersonalConnectionAdapter

  @impl true
  def link(account, worker, request, opts) do
    notify(opts, {:adapter_link, account, worker, request})

    Keyword.get_lazy(opts, :adapter_result, fn ->
      {:ok,
       %{
         worker_profile_ref: Keyword.get(opts, :worker_profile_ref, "profile-#{worker.id}"),
         provider: request.provider,
         authentication_mode: request.authentication_mode,
         availability: Keyword.get(opts, :availability, "available"),
         adapter_compatibility_version: Keyword.get(opts, :adapter_version, "connection/1")
       }}
    end)
  end

  @doc "Implements the six-argument RPC seam used by the production adapter."
  def request(account_id, device_workspace_id, worker_id, capability, params, opts) do
    notify(
      opts,
      {:rpc_request, account_id, device_workspace_id, worker_id, capability, params}
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
