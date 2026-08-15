defmodule SddOrchestrator.ProjectAssistant.ProjectAssistantCitation do
  @moduledoc """
  `entity:ProjectAssistantCitation` — one typed, authorization-checked link
  from an answer claim to its exact supporting source (AC-11, AC-12).

  Task 7 owns this schema. A citation is created only once, atomically with
  its turn, by `SddOrchestrator.ProjectAssistant.TurnAnswerStore` — nothing
  here updates a citation afterward, the same append-only treatment
  `ProjectAssistantTurn` gives one question.

  `source_type` is one of `"specification"`, `"repository"`, `"board"`,
  `"run"`, or `"evidence"` (a closed set, DB-enforced by a check
  constraint). `reference` carries only the exact typed identity for that
  type, never a full document body or an unbounded tool result:

    * `"specification"` — `%{"specification_id", "revision_id", "title"}`,
      resolved against `SpecificationStore.current_snapshot/2`'s current
      revision. A citation naming a superseded revision never resolves
      (`SddOrchestrator.ProjectAssistant.CitationResolver.resolve_specification/2`).
    * `"repository"` — `%{"path", "start_line", "end_line", "branch",
      "commit", "dirty", "stable"}`, resolved against a *freshly taken*
      `RepositoryObservation` for this turn. `"stable"` is always `true`
      here: an unstable observation never produces a repository citation at
      all (design.md's "no stale-source-current rule").
    * `"board"` — `%{"feature_id", "title", "lifecycle_column"}`.
    * `"run"` — `%{"run_id", "feature_id", "attempt_number", "state"}`.
    * `"evidence"` — `%{"evidence_id", "feature_id", "run_id", "kind",
      "outcome"}`.

  `excerpt` is the minimal cited snippet only (the "minimal excerpt policy"
  owned surface) — for a repository citation, a bounded line range read
  through `RepositoryDiscoverer.lines/6` and truncated well below its own
  byte budget; for other types, `nil` or a short quoted fragment, never a
  full document. It is encrypted at rest through `SddOrchestrator.Vault`
  exactly like `ProjectAssistantTurn.question_text` — repository-derived
  content gets the same treatment as private question text, never
  plaintext in a backup, log line, or crash report.

  design.md is explicit that the hosted control plane "may retain the
  minimum answer and exact path-and-line citation needed for the private
  conversation under the confirmed assistant processing boundary for at
  most the conversation lifetime" — this row, one per cited claim, is
  exactly that minimum. It is never a hosted repository source index, a raw
  search result, or an unrestricted tool payload.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias SddOrchestrator.ProjectAssistant.ProjectAssistantTurn
  alias SddOrchestrator.Projects.Project

  @source_types ~w(specification repository board run evidence)
  @max_excerpt_bytes 500

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime, updated_at: false]

  @type t :: %__MODULE__{}

  schema "project_assistant_citations" do
    field :source_type, :string
    field :reference, :map
    field :excerpt, SddOrchestrator.Encrypted.Binary, redact: true

    belongs_to :turn, ProjectAssistantTurn
    belongs_to :project, Project

    timestamps()
  end

  @spec source_types() :: [String.t()]
  def source_types, do: @source_types

  @spec max_excerpt_bytes() :: pos_integer()
  def max_excerpt_bytes, do: @max_excerpt_bytes

  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(citation, attrs) do
    citation
    |> cast(attrs, [:turn_id, :project_id, :source_type, :reference, :excerpt])
    |> validate_required([:turn_id, :project_id, :source_type, :reference])
    |> validate_inclusion(:source_type, @source_types)
    |> validate_length(:excerpt, max: @max_excerpt_bytes, count: :bytes)
    |> foreign_key_constraint(:turn_id)
    |> foreign_key_constraint(:project_id)
    |> check_constraint(:source_type, name: :project_assistant_citations_source_type_check)
  end
end
