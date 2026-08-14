defmodule SddOrchestrator.ProjectAssistant.RepositorySourceIndex do
  @moduledoc """
  `entity:RepositorySourceIndex` — the worker-local index's identity and
  version key (AC-18).

  design.md is explicit that this entity stays "entirely inside the worker
  boundary for both hosted and device projects" and that "the hosted control
  plane stores no source index, raw file, bulk scan result, or tool payload."
  That rules out an Ecto schema (a hosted Postgres copy) and rules out a
  device DETS record too — a device project's own stored specification,
  board, and conversation data is Orchestrator's authoritative record, but a
  repository's derived source index is deliberately not: durably storing it
  anywhere Orchestrator controls, even on the device side, would recreate the
  hosted-source copy the "Separate Destination-Local And Worker-Local
  Indexes" decision rules out, precisely because a device project's "worker"
  and "control plane" happen to run in the same process but must not share
  the same storage boundary.

  So this is a plain, non-persisted struct — the same treatment Task 4 gives
  `RepositoryObservation`, one step further: it carries only the identity and
  versioning metadata design.md's entity definition names ("keyed to
  project, repository authority, branch, commit, working-tree state, and
  index version"), never index content. A caller passes this struct to the
  worker on each call so the worker can decide whether *its own* locally
  cached index is still valid; Orchestrator never receives or stores the
  index content itself, only the bounded per-call `tree/1`, `search/1`, and
  `lines/1` results `RepositoryObservationAdapter` already returns, each
  already size-limited.

  `current?/2` is this module's invalidation and refresh check: an index
  built from one observation is valid only against a fresh observation whose
  project, repository authority, branch, commit, and working-tree state all
  still match. Any drift — including a different project or repository
  authority entirely — invalidates it, so a prior index can never be
  presented, reused, or credited to a different project or source authority
  than the one it was built for.
  """

  alias SddOrchestrator.ProjectAssistant.RepositoryObservation

  @index_version 1

  @enforce_keys [
    :project_id,
    :repository_provider,
    :repository_ref,
    :branch,
    :commit,
    :working_tree_state_key,
    :index_version
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          project_id: Ecto.UUID.t(),
          repository_provider: String.t() | nil,
          repository_ref: String.t() | nil,
          branch: String.t() | nil,
          commit: String.t() | nil,
          working_tree_state_key: String.t(),
          index_version: pos_integer()
        }

  @doc "The current index-key shape's version. Bumping it invalidates every prior key."
  @spec index_version() :: pos_integer()
  def index_version, do: @index_version

  @doc """
  Builds one index key from a `RepositoryObservation`.

  The working-tree-state key derives from the observation's dirty flag and
  post-scan digest — the same digest `RepositoryObservation.build/2` already
  uses to decide `stable?` — so an index built from an unstable observation
  is itself never treated as current once a later, differing observation
  arrives.
  """
  @spec build(RepositoryObservation.t()) :: t()
  def build(%RepositoryObservation{} = observation) do
    %__MODULE__{
      project_id: observation.project_id,
      repository_provider: observation.repository_provider,
      repository_ref: observation.repository_ref,
      branch: observation.branch,
      commit: observation.commit,
      working_tree_state_key: working_tree_state_key(observation),
      index_version: @index_version
    }
  end

  @doc """
  Whether `index` may still be treated as current given a freshly observed
  working tree.

  A mismatch on project, repository authority, branch, commit, working-tree
  state, or index version means the prior index — and any result implicitly
  associated with it — must not be reused as current (AC-18's "never serves
  stale source as current").
  """
  @spec current?(t(), RepositoryObservation.t()) :: boolean()
  def current?(%__MODULE__{} = index, %RepositoryObservation{} = observation) do
    index == build(observation)
  end

  @doc """
  The project- and source-authority scope this index may serve.

  Two indexes with equal scopes were built for the same project and
  repository authority; unequal scopes must never be treated as
  interchangeable, which is what keeps an index scoped to one project from
  being reused for another even before authorization is re-checked.
  """
  @spec scope(t()) :: {Ecto.UUID.t(), String.t() | nil, String.t() | nil}
  def scope(%__MODULE__{} = index),
    do: {index.project_id, index.repository_provider, index.repository_ref}

  defp working_tree_state_key(%RepositoryObservation{dirty: dirty, after_digest: after_digest}) do
    :sha256
    |> :crypto.hash("#{dirty}:#{after_digest}")
    |> Base.encode16(case: :lower)
  end
end
