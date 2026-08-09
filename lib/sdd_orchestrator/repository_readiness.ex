defmodule SddOrchestrator.RepositoryReadiness do
  @moduledoc """
  Independent repository readiness for the assistant, specification, agent
  execution, and release stages of one project.

  Each of the four axes is derived read-only from the approved repository
  execution profile (Slice 14), the selected pilot (Task 4), and the project's
  latest completed assessment. They are deliberately independent rather than a
  strict ladder: a repository conflict, staleness, multi-root boundary, or
  missing-check gap on one axis never blocks another axis whose own condition
  is unaffected by it. Only the absence of an approved profile or a selected
  pilot cascades forward, because nothing downstream can be evaluated at all
  without them.

  Nothing here writes anything. A blocked axis is a value, not an effect: nothing
  is refused, retried, or changed by reading this readiness.
  """

  alias SddOrchestrator.RepositoryAssessments
  alias SddOrchestrator.RepositoryAssessments.AssessmentStore
  alias SddOrchestrator.RepositoryPilots

  @type authority :: RepositoryPilots.authority()
  @type viewer :: RepositoryPilots.viewer()

  @type stage :: :assistant | :specification | :agent_execution | :release

  @type reason ::
          :no_approved_profile
          | :no_pilot_selected
          | :stale_base_revision
          | :changed_root
          | :unresolved_evidence_conflict
          | :unsupported_multi_root_boundary
          | :no_completed_assessment
          | :unreliable_required_check_contract

  @type axis_status :: :ready | {:blocked, reason()}

  @type t :: %__MODULE__{
          assistant: axis_status(),
          specification: axis_status(),
          agent_execution: axis_status(),
          release: axis_status(),
          earliest_blocked_stage: stage() | nil
        }

  @axes [:assistant, :specification, :agent_execution, :release]

  @enforce_keys @axes ++ [:earliest_blocked_stage]
  defstruct @enforce_keys

  @doc """
  Evaluates the four independent readiness axes for one project.

  `viewer` accepts the same hosted owner, device, or participant shapes
  `RepositoryPilots` accepts, and a participant reads exactly what an owner
  reads: nothing here is a decision only an owner may make. `opts` may inject
  `:assessment_store`, `:profile_store`, and `:pilot_store` for testability.

  There is no error return. An unapproved profile, an unselected pilot, an
  unauthorized viewer, and an unsupported viewer shape all fail the same way
  every read this evaluation is built from already fails: closed, as a blocked
  `:assistant` axis rather than as a distinct error, because none of those
  reads themselves distinguish "unauthorized" from "nothing to read" either.
  """
  @spec evaluate(viewer(), String.t(), keyword()) :: t()
  def evaluate(viewer, project_id, opts \\ []) do
    case current_profile(viewer, project_id, opts) do
      {:error, :no_approved_profile} ->
        build(%{
          assistant: {:blocked, :no_approved_profile},
          specification: {:blocked, :no_approved_profile},
          agent_execution: {:blocked, :no_approved_profile},
          release: {:blocked, :no_approved_profile}
        })

      {:ok, profile} ->
        case RepositoryPilots.current(viewer, project_id, opts) do
          {:error, :not_found} ->
            build(%{
              assistant: :ready,
              specification: {:blocked, :no_pilot_selected},
              agent_execution: {:blocked, :no_pilot_selected},
              release: {:blocked, :no_pilot_selected}
            })

          {:ok, _pilot} ->
            build(%{
              assistant: :ready,
              specification: :ready,
              agent_execution: agent_execution_status(viewer, project_id, profile, opts),
              release: release_status(profile)
            })
        end
    end
  end

  defp build(axes) do
    axes
    |> Map.put(:earliest_blocked_stage, earliest_blocked_stage(axes))
    |> then(&struct!(__MODULE__, &1))
  end

  defp earliest_blocked_stage(axes) do
    Enum.find(@axes, fn axis -> match?({:blocked, _reason}, Map.fetch!(axes, axis)) end)
  end

  # A repository's evidence-derived condition — staleness, root, evidence
  # conflict, or a multi-root boundary the profile could not resolve — bears
  # only on whether an agent may execute against it. None of it says anything
  # about whether the profile itself was approved or a pilot was picked, so
  # none of it belongs on any other axis.
  defp agent_execution_status(viewer, project_id, profile, opts) do
    assessment_store = Keyword.get(opts, :assessment_store, AssessmentStore)

    case assessment_store.latest_completed(viewer, project_id) do
      {:ok, completed} ->
        cond do
          profile.base_revision != completed.commit -> {:blocked, :stale_base_revision}
          profile.root != completed.root -> {:blocked, :changed_root}
          profile.conflicts != [] -> {:blocked, :unresolved_evidence_conflict}
          profile.multi_root_blockers != [] -> {:blocked, :unsupported_multi_root_boundary}
          true -> :ready
        end

      {:error, :not_found} ->
        # Defensive only: an approved profile is always built from a completed
        # assessment, so this should never happen in ordinary operation. Fail
        # closed rather than crash if it ever does.
        {:blocked, :no_completed_assessment}
    end
  end

  # An unreliable required-check contract bears only on whether a completion
  # claim can ever be verified, which is exactly what
  # `SddOrchestrator.Delivery.VerificationCompletion` already refuses
  # (`:required_check_contract_unknown`) for an empty contract. It says nothing
  # about whether an agent may currently execute against the repository.
  defp release_status(profile) do
    if profile.required_checks == [] or "missing_required_checks" in profile.gaps do
      {:blocked, :unreliable_required_check_contract}
    else
      :ready
    end
  end

  # Slice 14 remains the only writer of profile versions; this mirrors
  # `RepositoryPilots`' own private `current_profile/2` read convention over its
  # ascending list rather than reaching into Slice 14's modules directly.
  defp current_profile(viewer, project_id, opts) do
    review_opts = Keyword.take(opts, [:profile_store, :assessment_store])

    case RepositoryAssessments.profile_review(viewer, project_id, review_opts) do
      {:ok, %{profiles: []}} -> {:error, :no_approved_profile}
      {:ok, %{profiles: profiles}} -> {:ok, List.last(profiles)}
      {:error, _unavailable} -> {:error, :no_approved_profile}
    end
  end
end
