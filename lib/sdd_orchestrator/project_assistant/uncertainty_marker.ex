defmodule SddOrchestrator.ProjectAssistant.UncertaintyMarker do
  @moduledoc """
  Task 7's closed, typed vocabulary for visible answer uncertainty (AC-12):
  `partial`, `stale`, `excluded`, `unavailable`, `conflicting`, and
  `unstable`, each carrying a human-readable detail beside the affected
  conclusion.

  `SddOrchestrator.ProjectAssistant.TurnOrchestrator` attaches
  `:unavailable`, `:unstable`, `:stale`, and `:excluded` markers itself from
  a concrete resolution outcome it can verify — repository observation
  failure, an unstable working-tree scan, a superseded specification
  revision, or any other claim that failed to resolve against current
  authorized data. `:partial` and `:conflicting` are the answer-composition
  step's own uncertainty signal (something only the candidate answer itself
  can notice, such as "I could not fully answer" or "two sources
  disagree"); the orchestrator only validates and passes those through, it
  never invents one.

  A marker is data attached to the turn, never a tool-policy input: nothing
  in `ReadToolManifest`, `TrustedSkillBundle`, or `TurnBudget` ever reads a
  marker, matching the same one-way flow `UntrustedContent` already proves
  for the runtime contract.
  """

  @kinds ~w(partial stale excluded unavailable conflicting unstable)a

  @type kind :: :partial | :stale | :excluded | :unavailable | :conflicting | :unstable
  @type t :: %{type: kind(), detail: String.t()}

  @doc "The closed set of uncertainty-marker kinds."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "Builds one marker. `detail` must be a non-empty, human-readable string."
  @spec new(kind(), String.t()) :: t()
  def new(kind, detail) when kind in @kinds and is_binary(detail) and detail != "" do
    %{type: kind, detail: detail}
  end

  @doc "The plain, string-keyed, JSON-safe storage shape one marker gets."
  @spec to_map(t()) :: map()
  def to_map(%{type: type, detail: detail}) when type in @kinds and is_binary(detail) do
    %{"type" => Atom.to_string(type), "detail" => detail}
  end

  @doc """
  Validates and normalizes a caller-supplied (e.g. candidate-answer) marker
  map into `t()`. Refuses an unknown kind or a missing/empty detail rather
  than silently accepting arbitrary caller-declared text as one of the
  closed six.
  """
  @spec from_candidate(term()) :: {:ok, t()} | {:error, :invalid_marker}
  def from_candidate(%{type: type, detail: detail})
      when type in @kinds and is_binary(detail) and detail != "" do
    {:ok, %{type: type, detail: detail}}
  end

  def from_candidate(_other), do: {:error, :invalid_marker}
end
