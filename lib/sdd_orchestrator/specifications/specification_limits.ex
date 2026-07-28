defmodule SddOrchestrator.Specifications.SpecificationLimits do
  @moduledoc """
  Configured limits for authoritative specification documents and snapshots.

  Defaults are deterministic and can be tightened per deployment without
  changing the shared store contract.
  """

  @defaults [
    max_title_bytes: 200,
    max_actor_ref_bytes: 128,
    max_document_bytes: 256 * 1_024,
    max_revision_bytes: 768 * 1_024,
    max_specifications_per_project: 100,
    max_snapshot_bytes: 25 * 1_024 * 1_024
  ]

  @spec get(atom()) :: pos_integer()
  def get(name) do
    :sdd_orchestrator
    |> Application.get_env(:specification_limits, [])
    |> Keyword.get(name, Keyword.fetch!(@defaults, name))
  end

  @spec all() :: keyword(pos_integer())
  def all do
    Keyword.merge(@defaults, Application.get_env(:sdd_orchestrator, :specification_limits, []))
  end
end
