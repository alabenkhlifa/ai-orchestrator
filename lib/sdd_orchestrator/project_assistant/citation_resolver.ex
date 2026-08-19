defmodule SddOrchestrator.ProjectAssistant.CitationResolver do
  @moduledoc """
  Pure claim-to-source validation (AC-11, AC-12): given already-authorized,
  already-current data, resolve one claimed
  `SddOrchestrator.ProjectAssistant.ModelCompletionAdapter.citation_claim/0`
  into an exact `SddOrchestrator.ProjectAssistant.ProjectAssistantCitation`
  reference, or refuse.

  Every function here is a pure lookup against data the caller already
  fetched through an authorization-checked read (Task 3's
  `ProjectContextAssembler.assemble/3` for specification, board, run, and
  evidence claims; Task 4's `RepositoryObserver.observe/4` for repository
  claims). This module never itself authorizes, reads storage, or calls a
  worker — that keeps "was this claim allowed to be read" and "does this
  claim actually match what was read" as two separately provable
  properties, matching Task 5's `RepositoryDiscoverer.classify/2` doing the
  same pure-classification-over-already-fetched-data split.

  A specification claim naming a stale (non-current) revision, or any claim
  naming an id absent from the current context, is refused rather than
  silently narrowed to "closest match" — design.md's exact typed grounding
  decision: "The assistant must sometimes answer that evidence is
  unavailable or unstable instead of giving a complete-looking response."

  Repository resolution is split from the rest: `build_repository_reference/2`
  only shapes an already-current, already-stable observation's provenance
  into a citation reference. It takes no path yet unread — the caller
  (`SddOrchestrator.ProjectAssistant.TurnOrchestrator`) fetches the minimal
  excerpt through `RepositoryDiscoverer.lines/6` (itself authorization- and
  exclusion-checked) *before* calling this function, and never calls it at
  all for an unavailable or unstable observation.
  """

  alias SddOrchestrator.ProjectAssistant.ModelCompletionAdapter
  alias SddOrchestrator.ProjectAssistant.RepositoryObservation

  @type citation_reference :: map()
  @type citation_claim :: ModelCompletionAdapter.citation_claim()

  @doc "Resolves a specification claim against the current snapshot's minimized entries."
  @spec resolve_specification(citation_claim(), [map()]) ::
          {:ok, citation_reference()} | {:error, atom()}
  def resolve_specification(%{specification_id: id, revision_id: revision_id}, specifications)
      when is_list(specifications) do
    case Enum.find(specifications, &(&1["id"] == id)) do
      nil ->
        {:error, :not_found}

      %{"revision_id" => ^revision_id} = entry ->
        {:ok,
         %{"specification_id" => id, "revision_id" => revision_id, "title" => entry["title"]}}

      %{"revision_id" => _superseded} ->
        {:error, :stale}
    end
  end

  def resolve_specification(_claim, _specifications), do: {:error, :not_found}

  @doc "Resolves a board claim against the current board's flattened feature entries."
  @spec resolve_board(citation_claim(), %{String.t() => [map()]}) ::
          {:ok, citation_reference()} | {:error, atom()}
  def resolve_board(%{feature_id: id}, board_by_column) when is_map(board_by_column) do
    board_by_column
    |> Map.values()
    |> List.flatten()
    |> Enum.find(&(&1["id"] == id))
    |> case do
      nil ->
        {:error, :not_found}

      entry ->
        {:ok,
         %{
           "feature_id" => id,
           "title" => entry["title"],
           "lifecycle_column" => entry["lifecycle_column"]
         }}
    end
  end

  def resolve_board(_claim, _board), do: {:error, :not_found}

  @doc "Resolves a run claim against the current recent-run entries."
  @spec resolve_run(citation_claim(), [map()]) :: {:ok, citation_reference()} | {:error, atom()}
  def resolve_run(%{run_id: id}, recent_runs) when is_list(recent_runs) do
    case Enum.find(recent_runs, &(&1["run_id"] == id)) do
      nil ->
        {:error, :not_found}

      entry ->
        {:ok,
         %{
           "run_id" => id,
           "feature_id" => entry["feature_id"],
           "attempt_number" => entry["current_attempt_number"],
           "state" => entry["state"]
         }}
    end
  end

  def resolve_run(_claim, _recent_runs), do: {:error, :not_found}

  @doc "Resolves an evidence claim against the current accepted-evidence entries."
  @spec resolve_evidence(citation_claim(), [map()]) ::
          {:ok, citation_reference()} | {:error, atom()}
  def resolve_evidence(%{evidence_id: id}, accepted_evidence) when is_list(accepted_evidence) do
    case Enum.find(accepted_evidence, &(&1["id"] == id)) do
      nil ->
        {:error, :not_found}

      entry ->
        {:ok,
         %{
           "evidence_id" => id,
           "feature_id" => entry["feature_id"],
           "run_id" => entry["run_id"],
           "kind" => entry["kind"],
           "outcome" => entry["outcome"]
         }}
    end
  end

  def resolve_evidence(_claim, _accepted_evidence), do: {:error, :not_found}

  @doc """
  Shapes an already-current, already-stable observation's provenance into a
  repository citation reference. The caller must never invoke this for an
  observation with `stable?: false` — design.md's "no stale-source-current
  rule": a changed tree must never yield a stable citation.
  """
  @spec build_repository_reference(RepositoryObservation.t(), citation_claim()) ::
          citation_reference()
  def build_repository_reference(%RepositoryObservation{stable?: true} = observation, %{
        path: path,
        start_line: start_line,
        end_line: end_line
      }) do
    %{
      "path" => path,
      "start_line" => start_line,
      "end_line" => end_line,
      "branch" => observation.branch,
      "commit" => observation.commit,
      "dirty" => observation.dirty,
      "stable" => true
    }
  end
end
