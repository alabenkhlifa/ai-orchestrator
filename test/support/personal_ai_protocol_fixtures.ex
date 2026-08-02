defmodule SddOrchestrator.PersonalAIProtocolFixtures do
  @moduledoc false

  alias SddOrchestrator.AIRuntime.PersonalWorkerProtocol

  @account_id "9a7f1e34-6b2d-4c8a-9e5f-0d1c2b3a4956"
  @device_workspace_id "b4e2c1d0-8f6a-4b3c-9d2e-1f0a9b8c7d65"
  @request_id "c5f3d2e1-9a7b-4c6d-8e1f-2a3b4c5d6e70"
  @idempotency_key "personal-ai-idem-0001"

  def account_id, do: @account_id
  def device_workspace_id, do: @device_workspace_id
  def request_id, do: @request_id
  def idempotency_key, do: @idempotency_key

  def announcement(overrides \\ %{}) do
    Map.merge(
      %{
        "protocol_version" => PersonalWorkerProtocol.version(),
        "capabilities" => PersonalWorkerProtocol.capabilities()
      },
      Map.new(overrides)
    )
  end

  def request(overrides \\ %{}) do
    Map.merge(
      %{
        "request_id" => @request_id,
        "idempotency_key" => @idempotency_key,
        "account_id" => @account_id,
        "device_workspace_id" => @device_workspace_id,
        "capability" => "catalog/1",
        "params" => %{"kind" => "models"}
      },
      Map.new(overrides)
    )
  end

  def response(overrides \\ %{}) do
    Map.merge(
      %{
        "request_id" => @request_id,
        "account_id" => @account_id,
        "result" => %{"models" => ["configured-model"]}
      },
      Map.new(overrides)
    )
  end

  def oversized_params do
    %{"filler" => String.duplicate("x", PersonalWorkerProtocol.limit(:max_envelope_bytes) + 1)}
  end

  def oversized_result, do: oversized_params()
end
