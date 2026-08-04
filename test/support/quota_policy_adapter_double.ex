defmodule SddOrchestrator.QuotaPolicyAdapterDouble do
  @moduledoc """
  Deterministic test boundary for quota-policy evaluation.

  The double receives only the already authorized, minimized policy context
  and returns the exact result supplied by the owning test process.
  """

  @behaviour SddOrchestrator.AIRuntime.QuotaPolicyAdapter

  @impl true
  def evaluate(context, opts) do
    case Keyword.get(opts, :notify) do
      pid when is_pid(pid) -> send(pid, {:quota_policy_evaluate, context})
      _other -> :ok
    end

    Keyword.get(opts, :adapter_result, {:error, :invalid_request})
  end
end
