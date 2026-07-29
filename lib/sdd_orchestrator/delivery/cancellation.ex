defmodule SddOrchestrator.Delivery.Cancellation do
  @moduledoc """
  Ending one run for good, on the authority of the person accountable for it.

  Cancelling is the one delivery action that is deliberately narrower than the
  rest. Starting and retrying are collaborative — a ready feature and a stopped
  run are shared work anyone currently on the project may move. Cancelling
  throws work away, so only the participant who committed the project to this
  run, or the project's owner, may do it. Any other current participant is
  refused, and an initiator who has left the project takes no authority with
  them; the owner keeps theirs precisely so a departure cannot strand a run.

  Cancellation is terminal. The run's own transition table allows nothing out of
  `canceled`, so there is no resume and no second attempt: the history, the
  activity, and the evidence stay exactly where they are as governed records,
  and later development has to be a new run on a new branch. That is the point
  rather than a limitation — a cancelled run is a decision someone made, and
  reopening it would erase the decision.

  What the feature does next is decided by its requirements now, not by where it
  was when the run started. If the current revision still satisfies readiness the
  feature returns to `Ready for development`; otherwise it goes back to `Draft`,
  because something changed while the run was in flight and the next start would
  have nothing valid to work from.

  The worker is told separately. A cancel command is enqueued in the same
  transaction, so an agent that is still running is actually stopped rather than
  left working against a run the product has already ended.
  """

  alias SddOrchestrator.Delivery.{
    AgentRun,
    DeliveryStore,
    Feature,
    ParticipantGuard,
    Readiness,
    RunAttempt
  }

  @type authority :: DeliveryStore.authority()
  @type actor :: ParticipantGuard.actor()

  @type error ::
          :unauthorized
          | :no_active_run
          | :already_canceled
          | :unknown_feature
          | term()

  # Every non-terminal run, plus `failed`: a stopped run is still a run somebody
  # has to end before the feature can move on.
  @cancelable ~w(pending running blocked failed)

  @spec cancelable_states() :: [String.t()]
  def cancelable_states, do: @cancelable

  @doc """
  Cancels the feature's live run for the acting participant.

  The run is found first and the narrow authority checked against it, so a
  current participant who may not cancel learns that rather than learning
  whether a run exists. A run that is already `canceled` is refused without
  enqueueing a second instruction for the worker.
  """
  @spec cancel(authority(), actor(), map(), keyword()) :: {:ok, map()} | {:error, error()}
  def cancel(authority, actor, %{project: project, feature: feature}, opts \\ []) do
    with {:ok, member} <- ParticipantGuard.authorize_action(project.id, actor, :cancel_run),
         {:ok, run} <- cancelable_run(authority, project.id, feature.id),
         :ok <- cancel_authority(run, member),
         {:ok, current} <- fetch_feature(authority, project.id, run.feature_id) do
      column = return_column(authority, project.id, actor, run.feature_id)
      attempt = live_attempt(authority, project.id, run.id)

      commit(authority, run.project_id, steps(run, attempt, current, member, column, opts))
    end
  end

  @doc """
  The run this reader may actually cancel on this feature, if there is one.

  Read through the participation guard and the same narrow authority the action
  applies, so the button never appears for someone whose press would be refused.
  """
  @spec cancelable(authority(), actor(), map()) ::
          {:ok, AgentRun.t() | nil} | {:error, :unauthorized}
  def cancelable(authority, actor, %{project: project, feature: feature}) do
    with {:ok, member} <- ParticipantGuard.authorize_action(project.id, actor, :cancel_run) do
      case cancelable_run(authority, project.id, feature.id) do
        {:ok, run} -> {:ok, permitted(run, member)}
        {:error, _absent} -> {:ok, nil}
      end
    end
  end

  defp permitted(run, member) do
    case cancel_authority(run, member) do
      :ok -> run
      {:error, :unauthorized} -> nil
    end
  end

  # The two people who may end a run: whoever started it, and the one person
  # accountable for the project whatever else changes. Membership itself was
  # already revalidated by the guard, which is what removes a former initiator's
  # authority the moment they leave.
  defp cancel_authority(%AgentRun{initiator_account_id: initiator}, member) do
    if member.role == :owner or (not is_nil(initiator) and member.account_id == initiator) do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  # Four records, four steps, each written exactly once. The command names the
  # attempt it stops rather than creating one, because cancellation produces no
  # next attempt to reference.
  defp steps(run, attempt, feature, member, column, opts) do
    end_attempt(attempt) ++
      [
        {:run, {:transition_run, run, "canceled", []}},
        feature_step(feature, column),
        {:activity,
         {:append_activity,
          %{
            project_id: run.project_id,
            feature_id: run.feature_id,
            run_id: run.id,
            attempt_id: attempt && attempt.id,
            actor_kind: "participant",
            actor_account_id: member.account_id,
            type: "run_canceled",
            payload: %{
              "operation_key" => "cancel:#{run.id}",
              "branch" => run.branch,
              "attempt_number" => run.current_attempt_number,
              "returned_to" => column
            }
          }}},
        {:command,
         {:enqueue_command,
          %{
            id: Keyword.get(opts, :command_id, Ecto.UUID.generate()),
            project_id: run.project_id,
            run_id: run.id,
            attempt_id: attempt && attempt.id,
            operation: "cancel",
            # The version this commit produces, so a worker comparing versions is
            # fenced against the cancelled state rather than the one it replaces.
            expected_state_version: run.state_version + 1
          }}}
      ]
  end

  # A terminal attempt is already ended, and transitioning it again would be a
  # second write of the same record inside one commit.
  defp end_attempt(%RunAttempt{} = attempt) do
    if RunAttempt.current?(attempt) do
      [{:attempt, {:transition_attempt, attempt, "canceled"}}]
    else
      []
    end
  end

  defp end_attempt(nil), do: []

  # The feature moves only where its own lifecycle allows. Cancelling a run must
  # not invent an illegal move, so a feature the table cannot return from keeps
  # its column and only loses the status the ended run put on it.
  defp feature_step(feature, column) do
    if Feature.legal_transition?(feature.lifecycle_column, column) do
      {:feature, {:transition_feature, feature, column, []}}
    else
      {:feature, {:set_feature_status, feature, "none"}}
    end
  end

  # Readiness is re-read against the revision in play now. A specification that
  # changed during the run is exactly the case where returning the feature to
  # `Ready for development` would offer a start nobody can honour.
  defp return_column(authority, project_id, actor, feature_id) do
    if Readiness.start_available?(authority, project_id, actor, feature_id) do
      "ready_for_development"
    else
      "draft"
    end
  end

  # The run's own history is how a feature's runs are found, the same way the
  # start path finds a live one.
  defp cancelable_run(authority, project_id, feature_id) do
    authority
    |> DeliveryStore.list_activity(project_id, feature_id, limit: 200)
    |> Enum.filter(&(&1.type == "run_started"))
    |> Enum.map(& &1.run_id)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.map(&fetch_run(authority, project_id, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.split_with(&(&1.state in @cancelable))
    |> case do
      {[run | _rest], _ended} -> {:ok, run}
      {[], ended} -> {:error, refusal(ended)}
    end
  end

  # Saying a run was already cancelled is more useful than saying there is none,
  # and it is what a second press of the same button has to hear.
  defp refusal(runs) do
    if Enum.any?(runs, &(&1.state == "canceled")) do
      :already_canceled
    else
      :no_active_run
    end
  end

  defp fetch_run(authority, project_id, run_id) do
    case DeliveryStore.fetch_run(authority, project_id, run_id) do
      {:ok, run} -> run
      :error -> nil
    end
  end

  # The highest-numbered attempt, current or terminal: a cancelled run must name
  # the attempt it stopped even when that attempt already ended.
  defp live_attempt(authority, project_id, run_id) do
    case DeliveryStore.latest_attempt(authority, project_id, run_id) do
      {:ok, attempt} -> attempt
      :error -> nil
    end
  end

  defp fetch_feature(authority, project_id, feature_id) do
    case DeliveryStore.fetch_feature(authority, project_id, feature_id) do
      {:ok, feature} -> {:ok, feature}
      :error -> {:error, :unknown_feature}
    end
  end

  defp commit(authority, project_id, steps) do
    authority
    |> DeliveryStore.commit(project_id, steps)
    |> case do
      {:ok, results} -> {:ok, results}
      {:error, _step, reason} -> {:error, reason}
    end
  end
end
