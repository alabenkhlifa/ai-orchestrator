defmodule SddOrchestrator.Delivery.ProtocolLimits do
  @moduledoc """
  Configured payload limits for the worker protocol and execution manifests.

  Limits bound what one peer can push through the channel before any project
  persistence exists. Deployments may tighten them without changing the
  protocol contract.
  """

  @defaults [
    max_envelope_bytes: 256 * 1_024,
    max_manifest_bytes: 128 * 1_024,
    max_payload_bytes: 64 * 1_024,
    max_id_bytes: 64,
    max_reference_bytes: 512,
    max_text_bytes: 8_192,
    max_required_checks: 50,
    max_capabilities: 64,
    max_snapshot_attempts: 100
  ]

  @spec get(atom()) :: pos_integer()
  def get(name) do
    :sdd_orchestrator
    |> Application.get_env(:delivery_protocol_limits, [])
    |> Keyword.get(name, Keyword.fetch!(@defaults, name))
  end

  @spec all() :: keyword(pos_integer())
  def all do
    Keyword.merge(
      @defaults,
      Application.get_env(:sdd_orchestrator, :delivery_protocol_limits, [])
    )
  end
end
