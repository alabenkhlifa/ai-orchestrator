defmodule SddOrchestrator.Specifications.ProjectSpecification do
  @moduledoc """
  Stable project-scoped specification identity and current revision pointer.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias SddOrchestrator.Specifications.{SpecificationLimits, SpecificationRevision}

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  @type t :: %__MODULE__{}

  schema "project_specifications" do
    field :title, :string

    belongs_to :project, SddOrchestrator.Projects.Project
    belongs_to :current_revision, SpecificationRevision

    has_many :revisions, SpecificationRevision, foreign_key: :specification_id

    timestamps()
  end

  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(specification, attrs) do
    specification
    |> cast(attrs, [:id, :project_id, :title])
    |> trim_title()
    |> validate_required([:id, :project_id, :title])
    |> validate_length(:title, max: SpecificationLimits.get(:max_title_bytes), count: :bytes)
    |> foreign_key_constraint(:project_id)
    |> unique_constraint(:id, name: :project_specifications_pkey)
  end

  @spec current_revision_changeset(t(), SpecificationRevision.t()) :: Ecto.Changeset.t()
  def current_revision_changeset(specification, %SpecificationRevision{} = revision) do
    advance_changeset(specification, revision, %{})
  end

  @spec advance_changeset(t(), SpecificationRevision.t(), map()) :: Ecto.Changeset.t()
  def advance_changeset(specification, %SpecificationRevision{} = revision, attrs) do
    specification
    |> cast(attrs, [:title])
    |> trim_title()
    |> validate_required([:title])
    |> validate_length(:title, max: SpecificationLimits.get(:max_title_bytes), count: :bytes)
    |> put_change(:current_revision_id, revision.id)
    |> foreign_key_constraint(:current_revision_id)
  end

  defp trim_title(changeset) do
    case fetch_change(changeset, :title) do
      {:ok, title} when is_binary(title) ->
        title = String.trim(title)

        if title == "" or Regex.match?(~r/\p{Cc}/u, title) do
          changeset
          |> put_change(:title, title)
          |> add_error(:title, "must be a non-empty display title without control characters")
        else
          put_change(changeset, :title, title)
        end

      _other ->
        changeset
    end
  end
end
