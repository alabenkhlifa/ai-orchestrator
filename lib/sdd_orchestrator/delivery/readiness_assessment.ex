defmodule SddOrchestrator.Delivery.ReadinessAssessment do
  @moduledoc """
  What one exact specification revision still needs before development starts.

  An assessment is bound to the revision it judged. That binding is the whole
  point: a verdict about yesterday's requirements must not authorize starting
  work on today's, so a revision that moves invalidates the assessment rather
  than silently carrying its readiness forward.

  Findings are stored, not recomputed on read, because the user has to see the
  same list that produced the verdict. Each carries a visible blocking
  classification and an explanation in plain language — readiness is never a
  hidden score.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias SddOrchestrator.Delivery.{Feature, ReadinessGuidance}
  alias SddOrchestrator.Projects.Project

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  # Whether a guidance model took part in this verdict. It is recorded rather
  # than inferred, because "a model found nothing" and "no model was asked" are
  # the same empty list and mean opposite things to the person reading them.
  @guidance_values ~w(configured not_configured)

  @type t :: %__MODULE__{}

  schema "readiness_assessments" do
    field :specification_id, :string
    field :revision_id, :string
    field :revision_digest, :string
    field :findings, :map, default: %{}
    field :guidance, :string
    field :dismissed_ids, {:array, :string}, default: []
    field :version, :integer, default: 1
    field :assessed_at, :utc_datetime_usec

    belongs_to :project, Project
    belongs_to :feature, Feature

    timestamps()
  end

  @doc "Records one assessment of one exact revision."
  def upsert_changeset(assessment, attrs) do
    assessment
    |> cast(attrs, [
      :project_id,
      :feature_id,
      :specification_id,
      :revision_id,
      :revision_digest,
      :findings,
      :guidance,
      :assessed_at
    ])
    |> put_default_assessed_at()
    |> put_change(:dismissed_ids, [])
    |> put_change(:version, (assessment.version || 0) + 1)
    |> validate_required([
      :project_id,
      :feature_id,
      :specification_id,
      :revision_id,
      :revision_digest,
      :findings,
      :guidance,
      :assessed_at
    ])
    |> validate_inclusion(:guidance, @guidance_values)
    |> unique_constraint(:feature_id)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:feature_id)
  end

  @doc """
  Records the non-blocking suggestions an authorized user has dismissed.

  Only the caller's expected version is accepted, so a dismissal aimed at a
  finding list that has since been replaced is rejected rather than applied to
  different findings.
  """
  def dismissal_changeset(%__MODULE__{} = assessment, dismissed_ids, expected_version) do
    assessment
    |> change(%{})
    |> validate_expected_version(expected_version)
    |> put_change(:dismissed_ids, Enum.uniq(dismissed_ids))
    |> optimistic_lock(:version)
  end

  @doc "The findings this assessment recorded, in the order the boundary gave them."
  @spec findings(t()) :: [map()]
  def findings(%__MODULE__{findings: %{"findings" => findings}}) when is_list(findings),
    do: findings

  def findings(%__MODULE__{}), do: []

  @doc """
  The findings that still block development.

  A dismissal can never remove one: only non-blocking suggestions are
  dismissible, so this list ignores `dismissed_ids` entirely.
  """
  @spec blockers(t()) :: [map()]
  def blockers(%__MODULE__{} = assessment),
    do: assessment |> findings() |> Enum.filter(&(&1["blocking"] == true))

  @doc "The non-blocking suggestions that have not been dismissed."
  @spec suggestions(t()) :: [map()]
  def suggestions(%__MODULE__{dismissed_ids: dismissed} = assessment) do
    assessment
    |> findings()
    |> Enum.filter(&(&1["blocking"] != true and &1["id"] not in dismissed))
  end

  @doc "Whether one finding may be dismissed. A blocking finding never may."
  @spec dismissible?(t(), String.t()) :: boolean()
  def dismissible?(%__MODULE__{} = assessment, finding_id) do
    assessment
    |> findings()
    |> Enum.any?(&(&1["id"] == finding_id and &1["blocking"] != true))
  end

  @doc """
  Whether development may start against this assessment.

  False while any blocker remains, which is what makes `Start development`
  unavailable rather than merely discouraged.
  """
  @spec start_available?(t()) :: boolean()
  def start_available?(%__MODULE__{} = assessment), do: blockers(assessment) == []

  @doc """
  Whether the assessment still describes the revision it is being read against.

  A moved revision makes the verdict stale: it judged different requirements.
  """
  @spec current_for?(t(), String.t(), String.t()) :: boolean()
  def current_for?(%__MODULE__{} = assessment, revision_id, revision_digest),
    do: assessment.revision_id == revision_id and assessment.revision_digest == revision_digest

  @doc """
  Whether a guidance model took part in this verdict.

  A verdict recorded with no model configured answers false, so the screen can
  say what actually judged the feature instead of implying a model did.
  """
  @spec guidance_configured?(t()) :: boolean()
  def guidance_configured?(%__MODULE__{guidance: "not_configured"}), do: false
  def guidance_configured?(%__MODULE__{}), do: true

  @doc "The values the guidance flag may carry."
  @spec guidance_values() :: [String.t()]
  def guidance_values, do: @guidance_values

  @doc "The guidance categories a finding may carry."
  @spec categories() :: [String.t()]
  def categories, do: ReadinessGuidance.categories()

  defp put_default_assessed_at(changeset) do
    case get_field(changeset, :assessed_at) do
      nil -> put_change(changeset, :assessed_at, DateTime.utc_now())
      _present -> changeset
    end
  end

  defp validate_expected_version(changeset, expected) do
    if changeset.data.version == expected do
      changeset
    else
      add_error(changeset, :version, "is stale")
    end
  end
end
