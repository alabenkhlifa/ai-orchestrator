defmodule SddOrchestrator.ProjectAssistant.ProjectContextAssembler.Shared do
  @moduledoc """
  The minimization and content-versioning rules the hosted and device
  assemblers share, so the two authorities produce identically shaped
  `content` from their own raw reads rather than two independently
  maintained ideas of "minimum."

  Every function here only ever narrows a raw record down to the fields
  grounding needs. Nothing here reads anything itself: a field this module
  has never heard of (a repository path, a run log line, a specification
  document body, an unrelated feature's activity) cannot leak into `content`
  by omission, because it was never passed in.
  """

  alias SddOrchestrator.Delivery.{AgentRun, Evidence, Feature}
  alias SddOrchestrator.Specifications.SpecificationSnapshot

  @doc "The current specification snapshot narrowed to stable identity and revision only."
  @spec specification_entries(SpecificationSnapshot.t()) :: [map()]
  def specification_entries(%SpecificationSnapshot{specifications: entries}) do
    Enum.map(entries, fn entry ->
      %{"id" => entry.id, "title" => entry.title, "revision_id" => entry.revision_id}
    end)
  end

  @doc "Every fixed board column, populated from the project's current features."
  @spec board_by_column([Feature.t()]) :: %{String.t() => [map()]}
  def board_by_column(features) do
    grouped = Enum.group_by(features, & &1.lifecycle_column, &feature_entry/1)
    Map.new(Feature.columns(), &{&1, Map.get(grouped, &1, [])})
  end

  @doc "One feature narrowed to its board-visible identity and state."
  @spec feature_entry(Feature.t()) :: map()
  def feature_entry(%Feature{} = feature) do
    %{
      "id" => feature.id,
      "title" => feature.title,
      "lifecycle_column" => feature.lifecycle_column,
      "status" => feature.status,
      "state_version" => feature.state_version,
      "specification_id" => feature.specification_id,
      "assigned_account_id" => feature.assigned_account_id,
      "creator_account_id" => feature.creator_account_id
    }
  end

  @doc "One feature's most recent run narrowed to status, never a full run log."
  @spec run_entry(String.t(), AgentRun.t()) :: map()
  def run_entry(feature_id, %AgentRun{} = run) do
    %{
      "feature_id" => feature_id,
      "run_id" => run.id,
      "state" => run.state,
      "branch" => run.branch,
      "approved_slice" => run.approved_slice,
      "current_attempt_number" => run.current_attempt_number,
      "failure_reason" => run.failure_reason,
      "state_version" => run.state_version
    }
  end

  @doc "One current (non-superseded) item of evidence narrowed to accepted status only."
  @spec evidence_entry(Evidence.t()) :: map()
  def evidence_entry(%Evidence{} = evidence) do
    %{
      "id" => evidence.id,
      "feature_id" => evidence.feature_id,
      "run_id" => evidence.run_id,
      "kind" => evidence.kind,
      "name" => evidence.name,
      "outcome" => evidence.outcome,
      "source" => evidence.source,
      "recorded_at" => DateTime.to_iso8601(evidence.recorded_at),
      "state_version" => evidence.state_version
    }
  end

  @doc "Only the project's current, non-superseded evidence — never a replaced result."
  @spec current_evidence([Evidence.t()]) :: [Evidence.t()]
  def current_evidence(evidence), do: Enum.filter(evidence, &Evidence.current?/1)

  @doc """
  Assembles the final `content` map and its deterministic version digest.

  The digest is computed over a canonical (key-sorted) form of `content`
  rather than over an encoded string, so two assemblies of the same
  underlying data always produce the same `context_version` regardless of
  map key insertion order — the property the idempotent-rebuild proof
  depends on.
  """
  @spec build(map(), [map()], %{String.t() => [map()]}, [map()], [map()]) ::
          {map(), String.t()}
  def build(project_metadata, specifications, board, recent_runs, accepted_evidence) do
    content = %{
      "project" => project_metadata,
      "specifications" => specifications,
      "board" => board,
      "recent_runs" => recent_runs,
      "accepted_evidence" => accepted_evidence
    }

    {content, context_version(content)}
  end

  @spec context_version(map()) :: String.t()
  def context_version(content) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary(canonical(content)))
    |> Base.encode16(case: :lower)
  end

  defp canonical(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} -> {key, canonical(value)} end)
    |> Enum.sort()
  end

  defp canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)
  defp canonical(other), do: other
end
