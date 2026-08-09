defmodule SddOrchestrator.InitializationDispatchFixtures do
  @moduledoc false

  alias SddOrchestrator.Delivery.InitializationManifest

  @device_workspace_id "9f3e2b1a-0000-4000-8000-000000000001"
  @dispatch_id "dsp_01HZX0000000000000000009"

  def device_workspace_id, do: @device_workspace_id
  def dispatch_id, do: @dispatch_id

  def manifest_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        "manifest_version" => InitializationManifest.manifest_version(),
        "device_workspace_id" => @device_workspace_id,
        "dispatch_id" => @dispatch_id,
        "capability_grant" => "plan_discovery",
        "agent_ref" => %{"provider_ref" => "configured-agent", "model_ref" => "configured-model"},
        "instructions" => %{
          "kind" => "plan_discovery_turn",
          "message" => "What are you building?"
        }
      },
      Map.new(overrides)
    )
  end

  def manifest(overrides \\ %{}) do
    {:ok, manifest} = overrides |> manifest_attrs() |> InitializationManifest.new()
    manifest
  end

  def announcement(overrides \\ %{}) do
    Map.merge(
      %{"capability_grants" => InitializationManifest.capability_grants()},
      Map.new(overrides)
    )
  end
end
