defmodule SddOrchestrator.ProjectAssistant.RepositoryObservation do
  @moduledoc """
  `entity:RepositoryObservation` — one bounded, per-turn source-read result
  (AC-08, AC-09, AC-16).

  This is a plain, non-persisted struct, not an Ecto schema. design.md
  describes it as "one bounded source-read result" a turn consumes and
  cites, not stored history: the hosted control plane must not persist,
  cache, index, or log repository source or its derived index without a
  later separately approved processing boundary, and a stored citation must
  still reauthorize the underlying source before it resolves. Persisting
  this struct itself would create exactly the durable hosted source copy
  design.md's "Separate Destination-Local And Worker-Local Indexes" decision
  rules out. A later task's citation and answer-composition work reads this
  struct for one turn and keeps only the minimum cited excerpt and
  provenance fields it needs — never this struct wholesale.

  `stable?` is derived, never supplied directly by an adapter: the worker
  compares working-tree state at scan start and scan completion, and a
  mismatch marks the observation unstable (AC-09) rather than presenting a
  possibly-mixed snapshot as a stable current result.
  """

  @enforce_keys [
    :project_id,
    :actor_ref,
    :repository_provider,
    :repository_ref,
    :branch,
    :commit,
    :dirty,
    :scan_started_at,
    :scan_completed_at,
    :exclusions,
    :before_digest,
    :after_digest,
    :stable?
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          project_id: Ecto.UUID.t(),
          actor_ref: String.t(),
          repository_provider: String.t() | nil,
          repository_ref: String.t() | nil,
          branch: String.t() | nil,
          commit: String.t() | nil,
          dirty: boolean(),
          scan_started_at: DateTime.t(),
          scan_completed_at: DateTime.t(),
          exclusions: [String.t()],
          before_digest: String.t(),
          after_digest: String.t(),
          stable?: boolean()
        }

  @doc """
  Builds one observation from an authorized source target and the adapter's
  raw result, deriving `stable?` from the before/after digest comparison.
  """
  @spec build(map(), map()) :: t()
  def build(target, raw) do
    before_digest = Map.fetch!(raw, :before_digest)
    after_digest = Map.fetch!(raw, :after_digest)

    %__MODULE__{
      project_id: Map.fetch!(target, :project_id),
      actor_ref: Map.fetch!(target, :actor_ref),
      repository_provider: Map.get(target, :repository_provider),
      repository_ref: Map.get(target, :repository_ref),
      branch: Map.get(raw, :branch),
      commit: Map.get(raw, :commit),
      dirty: Map.fetch!(raw, :dirty),
      scan_started_at: Map.fetch!(raw, :scan_started_at),
      scan_completed_at: Map.fetch!(raw, :scan_completed_at),
      exclusions: Map.get(raw, :exclusions, []),
      before_digest: before_digest,
      after_digest: after_digest,
      stable?: before_digest == after_digest
    }
  end
end
