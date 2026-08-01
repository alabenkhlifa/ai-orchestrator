defmodule SddOrchestrator.Delivery.ReviewHandoff do
  @moduledoc """
  Where a proven agent run stops and a person takes over.

  A run that verified its work has done everything it is allowed to do. This is
  the only place that fact becomes a lifecycle move, and the destination is a
  constant: `Ready for review`. There is no destination argument, no completion
  API, and no path from here to `Done` — an agent may hand work to a reviewer,
  and a reviewer alone decides the feature is finished. The board's transition
  table refuses `In development` to `Done` outright, so the denial holds even if
  something else ever tried to make the move.

  The verdict is consumed, never re-derived. What moves the feature is the
  verified completion the gate already recorded, read back from the feature's
  own history, so the reviewer is offered exactly the branch and commit that
  were proved rather than a second opinion about them. A refused completion, or
  none at all, moves nothing.

  A preview is not part of this decision. Whether one is absent, pending,
  failed, timed out, expired, or superseded is visible elsewhere and reaches no
  branch of this module: verified work becomes reviewable either way, which is
  the whole reason previews were kept out of the verification verdict.

  Review responsibility is resolved at handoff time by `Assignment`, not
  restated here: the current assignee, otherwise the current creator, with the
  project owner as the fail-closed fallback. It is recorded as an account
  reference, so a later rename or departure is reflected when the screen renders
  rather than frozen into history, and no participant email exists anywhere on
  this path.

  Handing the same verified completion over twice moves nothing twice. The
  completion's own identifier is the operation key, and the append-only history
  is the ledger it is checked against.
  """

  alias SddOrchestrator.Delivery.{
    ActivityEntry,
    AgentRun,
    Assignment,
    DeliveryStore,
    Feature,
    ParticipantGuard,
    RunNotifications,
    RunTransitions,
    VerificationCompletion
  }

  @type authority :: DeliveryStore.authority()
  @type member :: ParticipantGuard.member()

  @type result :: %{
          applied?: boolean(),
          feature: Feature.t(),
          activity: ActivityEntry.t() | nil,
          responsible: member() | nil
        }

  @type error ::
          :not_verified
          | :unknown_feature
          | :run_not_active
          | :not_in_development
          | RunTransitions.error()

  # The one column a finished run may reach. `Done` is deliberately absent and
  # unreachable from here.
  @column "ready_for_review"

  @activity_type "run_completed"

  @spec column() :: String.t()
  def column, do: @column

  @spec activity_type() :: String.t()
  def activity_type, do: @activity_type

  @doc """
  Hands one verified run's work to human review.

  The run's own recorded verified completion is what authorizes the move, so a
  caller cannot offer a claim of its own. A run that verified nothing is refused
  with `:not_verified`, a run that already ended terminally with
  `:run_not_active`, and a feature that is not in development with
  `:not_in_development` — each before anything is written.

  Answers `applied?: false` when this exact verified completion was already
  handed over, which is what makes the call safe to retry.
  """
  @spec deliver(authority(), Ecto.UUID.t(), AgentRun.t()) :: {:ok, result()} | {:error, error()}
  def deliver(authority, project_id, %AgentRun{} = run) do
    with :ok <- active?(run),
         {:ok, verified} <- verified(authority, project_id, run),
         {:ok, feature} <- feature(authority, project_id, run) do
      handoff(authority, project_id, run, feature, verified)
    end
  end

  @doc """
  Who this feature's review is currently waiting on.

  Asked fresh rather than read from the handoff record, so someone who left
  after the run finished is never named as the reviewer. `nil` only when the
  project has no owner to fall back to at all, which leaves the caller to render
  its own neutral text instead of inventing a name.
  """
  @spec responsible(Ecto.UUID.t(), Feature.t()) :: member() | nil
  def responsible(project_id, %Feature{} = feature) do
    case Assignment.responsible(project_id, feature) do
      {:ok, member} -> member
      {:error, :unavailable} -> nil
    end
  end

  # A run that was canceled or has already ended has nothing left to hand over.
  # Checked before the history is read, so a terminal run cannot be walked into
  # review by a completion it recorded earlier.
  defp active?(%AgentRun{} = run) do
    if AgentRun.terminal?(run), do: {:error, :run_not_active}, else: :ok
  end

  defp verified(authority, project_id, run) do
    case VerificationCompletion.verified_completion(
           authority,
           project_id,
           run.feature_id,
           run.id
         ) do
      {:ok, entry} -> {:ok, entry}
      :error -> {:error, :not_verified}
    end
  end

  defp feature(authority, project_id, run) do
    case DeliveryStore.fetch_feature(authority, project_id, run.feature_id) do
      {:ok, feature} -> {:ok, feature}
      :error -> {:error, :unknown_feature}
    end
  end

  # The legality check is skipped only for a handoff that already happened,
  # because the feature it moved is of course no longer in development. Every
  # other illegal move is refused by name rather than as a stale write, so a
  # caller can tell "already done" from "cannot be done".
  defp handoff(authority, project_id, run, feature, verified) do
    key = operation_key(verified)

    if RunTransitions.applied?(authority, project_id, feature.id, key) or
         Feature.legal_transition?(feature.lifecycle_column, @column) do
      commit(authority, project_id, run, feature, verified, key)
    else
      {:error, :not_in_development}
    end
  end

  defp commit(authority, project_id, run, feature, verified, key) do
    member = responsible(project_id, feature)

    authority
    |> RunTransitions.apply(%{
      operation_key: key,
      project_id: project_id,
      feature: feature,
      feature_column: @column,
      activity: activity(project_id, run, feature, verified, member)
    })
    |> case do
      {:ok, %{applied?: applied?, results: results}} ->
        reviewable = Map.get(results, :feature, feature)
        notify(authority, project_id, run, reviewable, applied?)

        {:ok,
         %{
           applied?: applied?,
           feature: reviewable,
           activity: Map.get(results, :activity),
           responsible: member
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A handoff that already happened is not a new event, so nobody is told twice.
  defp notify(_authority, _project_id, _run, _feature, false), do: :ok

  defp notify(authority, project_id, run, feature, true) do
    # This move belongs to the feature: the run's own version is untouched here,
    # unlike a block or a terminal failure. The notification key still uses it,
    # so it is read back from the store rather than taken from a caller's
    # snapshot that may predate the attempt the run is now on.
    case DeliveryStore.fetch_run(authority, project_id, run.id) do
      {:ok, current} ->
        RunNotifications.deliver(project_id, current, feature, :ready_for_review)
        :ok

      :error ->
        :ok
    end
  end

  # The branch and commit are copied from the recorded verdict rather than from
  # the run, so what a reviewer is pointed at is what was actually proved.
  defp activity(project_id, run, feature, verified, member) do
    %{
      project_id: project_id,
      feature_id: feature.id,
      run_id: run.id,
      attempt_id: verified.attempt_id,
      actor_kind: "system",
      type: @activity_type,
      payload: %{
        "column" => @column,
        "branch" => verified.payload["branch"],
        "commit_sha" => verified.payload["commit_sha"],
        "attempt_number" => verified.payload["attempt_number"],
        "responsible_account_id" => member && member.account_id
      }
    }
  end

  defp operation_key(%ActivityEntry{id: id}), do: "review-handoff:" <> id
end
