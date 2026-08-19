defmodule SddOrchestrator.ProjectAssistant.ProjectContextAssembler.Hosted do
  @moduledoc """
  Hosted-authority raw reads for `ProjectContextAssembler`.

  Every read revalidates the acting participant's current project
  participation on its own call — nothing here caches an authorization
  result across reads, matching every other project-assistant surface. The
  general `ParticipantGuard.authorize/2` membership check gates project
  metadata and the specification snapshot (`current_snapshot/2` itself
  authorizes only by workspace-project identity, not by acting participant,
  exactly like `Features.available_specifications/4` already has to gate it
  before calling that same function). Board and evidence reads additionally
  pass their own capability-specific `authorize_action/3` gate, matching
  `Features.board/2` and `EvidencePresentation.list/4`.

  Any failure anywhere in the chain — a stale or absent participant, a
  project this workspace does not own, or an internal read failure —
  collapses to the same `{:error, :unauthorized}` a denied caller gets
  everywhere else in this slice, so nothing here becomes a second,
  distinguishable denial surface.
  """

  alias SddOrchestrator.Accounts.PersonalWorkspace
  alias SddOrchestrator.Delivery.{Activity, ActivityEntry, DeliveryStore, ParticipantGuard}
  alias SddOrchestrator.ProjectAssistant.ProjectContextAssembler.Shared
  alias SddOrchestrator.Projects
  alias SddOrchestrator.SpecificationStore

  @spec assemble(PersonalWorkspace.t(), String.t(), ParticipantGuard.actor()) ::
          {:ok, %{content: map(), context_version: String.t()}} | {:error, :unauthorized}
  def assemble(%PersonalWorkspace{} = authority, project_id, actor) do
    with {:ok, project} <- authorize(authority, project_id, actor),
         {:ok, snapshot} <- SpecificationStore.current_snapshot(authority, project_id) do
      features = DeliveryStore.list_features(authority, project_id, [])
      evidence = DeliveryStore.list_evidence(authority, project_id, current: true)

      {content, version} =
        Shared.build(
          project_metadata(project),
          Shared.specification_entries(snapshot),
          Shared.board_by_column(features),
          recent_runs(authority, project_id, features),
          Enum.map(Shared.current_evidence(evidence), &Shared.evidence_entry/1)
        )

      {:ok, %{content: content, context_version: version}}
    else
      _denied -> {:error, :unauthorized}
    end
  rescue
    Ecto.Query.CastError -> {:error, :unauthorized}
  end

  @doc """
  Revalidates every gate a stored projection's content depends on: current
  general participation, this workspace's ownership of the project, current
  board-read capability, and current evidence-read capability.

  `ProjectContextStore` reuses this for `get/3` and `delete/3` so a stored
  projection never outlives, or is read past, the exact authorization that
  was checked when it was built — a participant who currently lacks
  evidence-read capability cannot read cached evidence merely because a more
  privileged participant's earlier refresh cached it.
  """
  @spec authorize(PersonalWorkspace.t(), String.t(), ParticipantGuard.actor()) ::
          {:ok, term()} | {:error, :unauthorized}
  def authorize(authority, project_id, actor) do
    with {:ok, _member} <- ParticipantGuard.authorize(project_id, actor),
         {:ok, project} <- fetch_project(authority, project_id),
         {:ok, _member} <- ParticipantGuard.authorize_action(project_id, actor, :view_board),
         {:ok, _member} <- ParticipantGuard.authorize_action(project_id, actor, :read_evidence) do
      {:ok, project}
    else
      _denied -> {:error, :unauthorized}
    end
  rescue
    Ecto.Query.CastError -> {:error, :unauthorized}
  end

  defp fetch_project(authority, project_id) do
    case Projects.get_project(authority, project_id) do
      nil -> {:error, :unauthorized}
      project -> {:ok, project}
    end
  end

  defp project_metadata(project) do
    %{
      "id" => project.id,
      "name" => project.name,
      "storage_mode" => project.storage_mode,
      "lifecycle_state" => project.lifecycle_state
    }
  end

  # The current run status for every feature that has ever started one. The
  # most recent "run_started" activity entry names it — the same rule
  # `FeatureDetailLive.current_run_id/1` already uses for one feature — read
  # here through the authority-dispatching `DeliveryStore.list_activity/4`
  # instead of the hosted-only `Activity` convenience wrapper, so the exact
  # same logic also works unmodified for a device-authoritative project.
  defp recent_runs(authority, project_id, features) do
    Enum.flat_map(features, fn feature ->
      case current_run(authority, project_id, feature.id) do
        {:ok, run} -> [Shared.run_entry(feature.id, run)]
        :none -> []
      end
    end)
  end

  defp current_run(authority, project_id, feature_id) do
    opts = [limit: Activity.max_limit()]

    with run_id when is_binary(run_id) <-
           authority
           |> DeliveryStore.list_activity(project_id, feature_id, opts)
           |> last_run_id(),
         {:ok, run} <- DeliveryStore.fetch_run(authority, project_id, run_id) do
      {:ok, run}
    else
      _absent -> :none
    end
  end

  defp last_run_id(entries) do
    entries
    |> Enum.filter(&(&1.type == "run_started"))
    |> List.last()
    |> case do
      nil -> nil
      %ActivityEntry{} = entry -> entry.run_id
    end
  end
end
