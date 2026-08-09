defmodule SddOrchestrator.Delivery.LocalWorkerRuntimeProjection do
  @moduledoc """
  Combines a governed local-worker run's live snapshot with the reused
  `capability:ai-runtime-observation` connection, model, effort, and quota
  projection.

  `RuntimeProjections.owner_projection/3` authorizes strictly by account
  ownership of the pinned session's connection, with no project-owner
  exception. Since only the run initiator's own personal AI connection is ever
  eligible to be pinned (see specs/34-local-worker-runtime-governance/design.md,
  "Present the result next to the run's existing activity view"), the
  initiator is the only viewer who can ever succeed there; every other current
  authorized participant, including the project owner when they are not the
  initiator, falls through to `participant_projection/4`'s own authorization.

  An ungoverned run (no `LocalWorkerRunGovernance` row) has nothing to
  present, so this never calls `RuntimeProjections` for one.
  """

  alias SddOrchestrator.AIRuntime.RuntimeProjections

  alias SddOrchestrator.Delivery.{
    AgentRun,
    LocalWorkerRunGovernance,
    LocalWorkerRuntimeSnapshot,
    RunAttempt
  }

  @type audience :: :owner | :participant

  @spec for_run(
          AgentRun.t(),
          RunAttempt.t(),
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          RuntimeProjections.actor()
        ) :: {:ok, :ungoverned} | {:ok, {audience(), map()}} | {:error, :unavailable}
  def for_run(%AgentRun{} = run, %RunAttempt{} = attempt, project_id, viewer_account_id, actor) do
    case LocalWorkerRunGovernance.for_run(run.id) do
      nil -> {:ok, :ungoverned}
      governance -> present(governance, run, attempt, project_id, viewer_account_id, actor)
    end
  end

  defp present(governance, run, attempt, project_id, viewer_account_id, actor) do
    snapshot = LocalWorkerRuntimeSnapshot.snapshot(run, attempt)

    case RuntimeProjections.owner_projection(viewer_account_id, governance.session_id) do
      {:ok, projection} -> {:ok, {:owner, Map.put(projection, :snapshot, snapshot)}}
      {:error, _reason} -> present_as_participant(governance, project_id, actor, snapshot)
    end
  end

  defp present_as_participant(governance, project_id, actor, snapshot) do
    case RuntimeProjections.participant_projection(project_id, actor, governance.session_id) do
      {:ok, projection} -> {:ok, {:participant, Map.put(projection, :snapshot, snapshot)}}
      {:error, _reason} -> {:error, :unavailable}
    end
  end
end
