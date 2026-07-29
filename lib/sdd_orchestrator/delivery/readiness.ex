defmodule SddOrchestrator.Delivery.Readiness do
  @moduledoc """
  Evaluating whether one feature's requirements are ready for development.

  This is the consumer side of two other boundaries and the owner of neither.
  Requirements come from `capability:project-specification-store`, and the
  judgement comes from the configured guidance adapter; what lives here is the
  durable verdict, bound to the exact revision it judged.

  Nothing here starts work. A ready assessment makes `Start development`
  available to an authorized participant — it does not press the button, and it
  never overrides a blocker. `assess/3` replaces the current assessment rather
  than appending another, because a feature has one readiness answer and a
  history of contradictory verdicts would tell the user nothing.
  """

  alias SddOrchestrator.Delivery.{
    Activity,
    ParticipantGuard,
    ReadinessAssessment,
    ReadinessGuidance
  }

  alias SddOrchestrator.Accounts.{DeviceWorkspace, PersonalWorkspace}
  alias SddOrchestrator.Repo
  alias SddOrchestrator.SpecificationStore

  @type actor :: ParticipantGuard.actor()
  @type authority :: PersonalWorkspace.t() | DeviceWorkspace.t()

  @type error ::
          :unauthorized
          | :no_specification
          | :not_dismissible
          | ReadinessGuidance.reason()

  @doc """
  Assesses the feature's current specification revision and records the verdict.

  The assessment replaces any earlier one for that feature and appends a
  `readiness_evaluated` entry so the history shows when the answer changed and
  what it was.
  """
  @spec assess(authority(), actor(), map()) ::
          {:ok, ReadinessAssessment.t()} | {:error, error()}
  def assess(authority, actor, %{project: project, feature: feature}) do
    with {:ok, member} <-
           ParticipantGuard.authorize_action(project.id, actor, :view_feature),
         {:ok, current} <- current_revision(authority, project.id),
         {:ok, input} <- project_input(feature, current),
         {:ok, assessment} <- ReadinessGuidance.assess(input) do
      record(project, feature, current, assessment, member)
    end
  end

  @doc "Returns the feature's current assessment, when it has one."
  @spec current(Ecto.UUID.t(), actor(), Ecto.UUID.t()) ::
          {:ok, ReadinessAssessment.t()} | {:error, :unauthorized | :not_found}
  def current(project_id, actor, feature_id) do
    with {:ok, _member} <- ParticipantGuard.authorize_action(project_id, actor, :view_feature) do
      case Repo.get_by(ReadinessAssessment, project_id: project_id, feature_id: feature_id) do
        nil -> {:error, :not_found}
        assessment -> {:ok, assessment}
      end
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_found}
  end

  @doc """
  Reports whether one finding may be dismissed.

  A blocking finding never may, whoever asks and however the request is
  phrased. This is the invariant the dismissal action is built on rather than a
  check the caller may skip.
  """
  @spec dismissible?(ReadinessAssessment.t(), String.t()) :: boolean()
  def dismissible?(assessment, finding_id),
    do: ReadinessAssessment.dismissible?(assessment, finding_id)

  @doc """
  Whether `Start development` may be offered for this feature right now.

  Requires a current assessment, bound to the revision in play, with no
  remaining blocker. An absent or superseded assessment is not readiness.
  """
  @spec start_available?(authority(), Ecto.UUID.t(), actor(), Ecto.UUID.t()) ::
          boolean()
  def start_available?(authority, project_id, actor, feature_id) do
    with {:ok, assessment} <- current(project_id, actor, feature_id),
         {:ok, current} <- current_revision(authority, project_id),
         true <-
           ReadinessAssessment.current_for?(
             assessment,
             revision_id(current),
             revision_digest(current)
           ) do
      ReadinessAssessment.start_available?(assessment)
    else
      _unavailable -> false
    end
  end

  @doc "The guided structure a feature's requirements are expected to describe."
  @spec guided_structure() :: [%{key: String.t(), label: String.t(), hint: String.t()}]
  def guided_structure do
    [
      %{
        key: "outcome",
        label: "The outcome",
        hint: "What someone can do afterwards that they cannot do now."
      },
      %{
        key: "users",
        label: "Who it is for",
        hint: "The people who will use this, in your own words."
      },
      %{
        key: "rules",
        label: "Rules that must hold",
        hint: "What must always or never happen, including the awkward cases."
      },
      %{
        key: "done",
        label: "How you will know it works",
        hint: "What you would check to accept the result."
      }
    ]
  end

  defp record(project, feature, current, assessment, member) do
    attrs = %{
      project_id: project.id,
      feature_id: feature.id,
      specification_id: specification_id(current),
      revision_id: revision_id(current),
      revision_digest: revision_digest(current),
      findings: %{"findings" => Map.get(assessment, "findings", [])}
    }

    existing = Repo.get_by(ReadinessAssessment, feature_id: feature.id) || %ReadinessAssessment{}

    with {:ok, saved} <-
           existing |> ReadinessAssessment.upsert_changeset(attrs) |> Repo.insert_or_update() do
      append_activity(project, feature, saved, member)
      {:ok, saved}
    end
  end

  # The activity records the verdict's shape, never the findings themselves:
  # the assessment already holds them, and copying requirement text into
  # history would duplicate the specification store's content.
  defp append_activity(project, feature, assessment, member) do
    Activity.append(%{
      project_id: project.id,
      feature_id: feature.id,
      actor_kind: "participant",
      actor_account_id: member.account_id,
      type: "readiness_evaluated",
      payload: %{
        "revision_id" => assessment.revision_id,
        "blocking" => length(ReadinessAssessment.blockers(assessment)),
        "suggestions" => length(ReadinessAssessment.suggestions(assessment)),
        "ready" => ReadinessAssessment.start_available?(assessment)
      }
    })
  end

  # The snapshot deliberately carries no digest, so the revision binding is read
  # through `get_current/3`. Binding to a digest rather than an identity is what
  # makes an edited revision invalidate its verdict.
  defp current_revision(authority, project_id) do
    with {:ok, %{specifications: [entry | _rest]}} <-
           SpecificationStore.current_snapshot(authority, project_id),
         {:ok, current} <- SpecificationStore.get_current(authority, project_id, entry.id) do
      {:ok, current}
    else
      _unavailable -> {:error, :no_specification}
    end
  end

  defp project_input(feature, current) do
    ReadinessGuidance.project(
      %{"title" => feature.title},
      %{
        "id" => revision_id(current),
        "digest" => revision_digest(current),
        "requirements" => requirements(current)
      }
    )
  end

  defp specification_id(%{specification: specification}), do: specification.id
  defp revision_id(%{revision: revision}), do: revision.id
  defp revision_digest(%{revision: revision}), do: revision.content_digest
  defp requirements(%{revision: revision}), do: revision.requirements_document || ""
end
