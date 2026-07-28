defmodule SddOrchestrator.Specifications.SpecificationRevision do
  @moduledoc """
  One immutable, complete `requirements`, `design`, and `tasks` revision.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias SddOrchestrator.Specifications.SpecificationLimits

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime, updated_at: false]

  @type t :: %__MODULE__{}

  schema "specification_revisions" do
    field :sequence, :integer
    field :requirements_document, :string
    field :design_document, :string
    field :tasks_document, :string
    field :content_digest, :string
    field :actor_ref, :string

    belongs_to :specification, SddOrchestrator.Specifications.ProjectSpecification
    belongs_to :project, SddOrchestrator.Projects.Project

    timestamps()
  end

  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(revision, attrs) do
    revision
    |> cast(attrs, [
      :id,
      :specification_id,
      :project_id,
      :sequence,
      :requirements_document,
      :design_document,
      :tasks_document,
      :content_digest,
      :actor_ref
    ])
    |> validate_required([
      :id,
      :specification_id,
      :project_id,
      :sequence,
      :requirements_document,
      :design_document,
      :tasks_document,
      :content_digest
    ])
    |> validate_number(:sequence, greater_than: 0)
    |> validate_length(:content_digest, is: 64)
    |> validate_length(:actor_ref,
      max: SpecificationLimits.get(:max_actor_ref_bytes),
      count: :bytes
    )
    |> validate_change(:actor_ref, fn :actor_ref, actor_ref ->
      if String.contains?(actor_ref, "@"),
        do: [actor_ref: "must be a non-email reference"],
        else: []
    end)
    |> foreign_key_constraint(:specification_id)
    |> foreign_key_constraint(:project_id)
    |> unique_constraint(:sequence,
      name: :specification_revisions_specification_id_sequence_index
    )
    |> check_constraint(:sequence, name: :specification_revisions_sequence_positive)
  end
end
