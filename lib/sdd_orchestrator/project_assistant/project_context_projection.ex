defmodule SddOrchestrator.ProjectAssistant.ProjectContextProjection do
  @moduledoc """
  One project's destination-local, replaceable stored-context projection.

  This accelerates default question grounding (AC-07) with the minimum
  current authoritative project data a turn needs before any repository
  observation is considered: current project metadata, current specification
  identity and revision references, current board state, recent run status,
  and accepted evidence.

  It deliberately carries no specification `requirements`, `design`, or
  `tasks` document body — the same choice `RepositoryPilotSelection` already
  makes for the piloted specification it references: this projection points
  at the authoritative `capability:project-specification-store` snapshot by
  stable specification id and revision id, it never becomes a second copy of
  it. A turn that needs the full current text reads
  `SpecificationStore.current_snapshot/2` directly.

  It also carries no repository path, source, source index, prior
  specification revision, raw run log, or unrelated feature activity (AC-17).
  Those never enter `content` in the first place; there is nothing here to
  filter them out of after the fact.

  One row per project (`unique_index` on `project_id`): a rebuild replaces
  the single current projection rather than accumulating stale history, the
  same replace-in-place shape `RepositoryPilotSelection` uses for its one
  current pilot.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias SddOrchestrator.Projects.Project

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  @type t :: %__MODULE__{}

  schema "project_context_projections" do
    field :context_version, :string
    field :content, :map
    field :refreshed_at, :utc_datetime

    belongs_to :project, Project

    timestamps()
  end

  @spec upsert_changeset(t(), map()) :: Ecto.Changeset.t()
  def upsert_changeset(projection, attrs) do
    projection
    |> cast(attrs, [:id, :project_id, :context_version, :content, :refreshed_at])
    |> validate_required([:project_id, :context_version, :content, :refreshed_at])
    |> foreign_key_constraint(:project_id)
    |> unique_constraint(:project_id, name: :project_context_projections_project_id_index)
  end
end
