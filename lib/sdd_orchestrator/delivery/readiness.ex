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

  Two things are judged here, not one. The structural part is this module's own
  work: a guided part with nothing under it blocks, and no model is needed to
  see that. The guidance part is the adapter's, and it adds to the structural
  findings rather than replacing them. That is what lets a deployment with no
  guidance model still answer, and it is why an unconfigured adapter is recorded
  as a fact about the deployment instead of raised as a failure. A configured
  adapter that fails is a failure: nobody judged the feature, and an empty list
  would claim otherwise.

  Only the feature's own linked specification is read. Judging one feature by
  another feature's words would be a wrong answer that looks like a right one.
  """

  alias SddOrchestrator.Delivery.{
    Activity,
    Feature,
    GuidedRequirements,
    ParticipantGuard,
    ReadinessAssessment,
    ReadinessGuidance
  }

  alias SddOrchestrator.Accounts.{DeviceWorkspace, PersonalWorkspace}
  alias SddOrchestrator.Repo
  alias SddOrchestrator.SpecificationStore

  # Structural finding ids carry their own prefix so they cannot be confused
  # with an id a guidance model chose.
  @structural_prefix "structural-"

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
         {:ok, current} <- current_revision(authority, project.id, feature),
         {:ok, input} <- project_input(feature, current),
         {:ok, guided, guidance} <- guidance_findings(input) do
      findings = merge_findings(structural_findings(requirements(current)), guided)

      record(project, feature, current, findings, guidance, member)
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
         {:ok, feature} <- feature(project_id, feature_id),
         {:ok, current} <- current_revision(authority, project_id, feature),
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

  # An unconfigured deployment is a fact about this control plane, so the
  # structural verdict still stands and the flag records what judged it. Every
  # other reason means nobody judged the feature at all, and an empty finding
  # list would read as "nothing blocks this", which is a claim nothing earned.
  defp guidance_findings(input) do
    case ReadinessGuidance.assess(input) do
      {:ok, assessment} -> {:ok, Map.get(assessment, "findings", []), "configured"}
      {:error, :not_configured} -> {:ok, [], "not_configured"}
      {:error, reason} -> {:error, reason}
    end
  end

  # One blocking finding per guided part with nothing under it. This is the
  # readiness a deployment always has: it needs no model, and it is the part a
  # person can always act on by writing the missing words.
  defp structural_findings(requirements) do
    parts = GuidedRequirements.parse(requirements)

    GuidedRequirements.structure()
    |> Enum.filter(&blank?(Map.get(parts, &1.key)))
    |> Enum.map(&structural_finding/1)
  end

  # The id is derived from the part key so it is the same id on every
  # assessment. A dismissal or a rendering keyed to a random id would point at
  # nothing the next time readiness ran.
  defp structural_finding(part) do
    %{
      "id" => @structural_prefix <> part.key,
      "category" => "missing",
      "blocking" => true,
      "summary" => "Nothing is written under \"#{part.label}\".",
      "explanation" => "Fill this part in before development starts. " <> part.hint
    }
  end

  # Structural findings win an id collision. A guidance finding that reused one
  # of their ids could otherwise present itself as a dismissible suggestion
  # carrying a blocker's identity.
  defp merge_findings(structural, guided) do
    ids = MapSet.new(structural, & &1["id"])

    structural ++ Enum.reject(guided, &MapSet.member?(ids, &1["id"]))
  end

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_absent), do: true

  defp record(project, feature, current, findings, guidance, member) do
    attrs = %{
      project_id: project.id,
      feature_id: feature.id,
      specification_id: specification_id(current),
      revision_id: revision_id(current),
      revision_digest: revision_digest(current),
      findings: %{"findings" => findings},
      guidance: guidance
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

  # The feature's own specification and no other. A feature that has none is
  # refused, because guessing which specification describes it would produce a
  # verdict about somebody else's words.
  #
  # Binding to a digest rather than an identity is what makes an edited revision
  # invalidate its verdict, so the revision is read through `get_current/3`.
  defp current_revision(authority, project_id, %{specification_id: specification_id})
       when is_binary(specification_id) do
    case SpecificationStore.get_current(authority, project_id, specification_id) do
      {:ok, current} -> {:ok, current}
      _unavailable -> {:error, :no_specification}
    end
  end

  defp current_revision(_authority, _project_id, _feature), do: {:error, :no_specification}

  defp feature(project_id, feature_id) do
    case Repo.get_by(Feature, id: feature_id, project_id: project_id) do
      nil -> {:error, :no_specification}
      feature -> {:ok, feature}
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
