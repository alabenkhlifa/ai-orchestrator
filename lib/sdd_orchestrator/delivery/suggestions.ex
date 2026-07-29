defmodule SddOrchestrator.Delivery.Suggestions do
  @moduledoc """
  Dismissing a non-blocking suggestion, and the readiness that follows.

  Dismissal exists so guidance stays useful without becoming an obstacle: a
  suggestion someone has considered and decided against should stop competing
  for attention. A blocker is a different thing entirely and is never
  dismissible here, whatever the request says.

  Reaching readiness is a separate, explicit outcome rather than a side effect
  of the last dismissal. `promote/4` moves the feature to `Ready for
  development` when nothing blocks it — and starting development still needs a
  person to press the button afterwards.
  """

  alias SddOrchestrator.Delivery.{
    ParticipantGuard,
    Readiness,
    ReadinessAssessment,
    RunTransitions
  }

  alias SddOrchestrator.Repo

  @type actor :: ParticipantGuard.actor()

  @type error ::
          :unauthorized
          | :not_found
          | :not_dismissible
          | :stale_assessment
          | :not_ready
          | :stale_state

  @doc """
  Dismisses one non-blocking suggestion against the caller's expected version.

  The blocking classification is re-read from the stored assessment at this
  moment rather than trusted from the request, so a finding that was
  non-blocking when the screen rendered but blocking in the current assessment
  is refused.
  """
  @spec dismiss(Ecto.UUID.t(), actor(), Ecto.UUID.t(), String.t(), pos_integer()) ::
          {:ok, ReadinessAssessment.t()} | {:error, error()}
  def dismiss(project_id, actor, feature_id, finding_id, expected_version) do
    with {:ok, _member} <- ParticipantGuard.authorize_action(project_id, actor, :assign),
         {:ok, assessment} <- Readiness.current(project_id, actor, feature_id),
         # Freshness first: against a superseded finding list, nothing else the
         # request says is meaningful, and "that finding is gone" would be a
         # confusing way to report "the list changed".
         :ok <- fresh?(assessment, expected_version),
         :ok <- dismissible(assessment, finding_id) do
      record(assessment, finding_id, expected_version)
    end
  end

  @doc """
  Moves a feature to `Ready for development` once nothing blocks it.

  Readiness is committed as its own transition with its own activity entry, so
  the board shows a decision that happened rather than a state someone
  inferred.
  """
  @spec promote(Readiness.authority(), actor(), map(), String.t()) ::
          {:ok, map()} | {:error, error()}
  def promote(authority, actor, %{project: project, feature: feature}, operation_key) do
    with {:ok, member} <- ParticipantGuard.authorize_action(project.id, actor, :assign),
         {:ok, assessment} <- Readiness.current(project.id, actor, feature.id),
         :ok <- ready?(assessment) do
      RunTransitions.apply(authority, %{
        operation_key: operation_key,
        project_id: project.id,
        feature: feature,
        feature_column: "ready_for_development",
        activity: %{
          project_id: project.id,
          feature_id: feature.id,
          actor_kind: "participant",
          actor_account_id: member.account_id,
          type: "readiness_evaluated",
          payload: %{"revision_id" => assessment.revision_id, "ready" => true}
        }
      })
    end
  end

  @doc "The suggestions still worth showing, and the blockers that remain."
  @spec visible(ReadinessAssessment.t()) :: %{blockers: [map()], suggestions: [map()]}
  def visible(assessment) do
    %{
      blockers: ReadinessAssessment.blockers(assessment),
      suggestions: ReadinessAssessment.suggestions(assessment)
    }
  end

  defp record(assessment, finding_id, expected_version) do
    assessment
    |> ReadinessAssessment.dismissal_changeset(
      [finding_id | assessment.dismissed_ids],
      expected_version
    )
    |> Repo.update()
    |> case do
      {:ok, updated} -> {:ok, updated}
      {:error, _changeset} -> {:error, :stale_assessment}
    end
  rescue
    Ecto.StaleEntryError -> {:error, :stale_assessment}
  end

  defp dismissible(assessment, finding_id) do
    if ReadinessAssessment.dismissible?(assessment, finding_id) do
      :ok
    else
      {:error, :not_dismissible}
    end
  end

  defp fresh?(%{version: version}, version), do: :ok
  defp fresh?(_assessment, _expected), do: {:error, :stale_assessment}

  defp ready?(assessment) do
    if ReadinessAssessment.start_available?(assessment) do
      :ok
    else
      {:error, :not_ready}
    end
  end
end
