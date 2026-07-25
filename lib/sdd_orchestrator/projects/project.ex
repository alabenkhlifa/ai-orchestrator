defmodule SddOrchestrator.Projects.Project do
  @moduledoc """
  A minimal project read-model: the stable identity and display name the catalog
  needs to list projects and route on their existence.

  This task owns only the read-model. The project-confirmation task extends this
  schema with the canonical comparison key and workspace uniqueness, the selected
  storage mode, lifecycle state, and the repository connection, and owns the
  atomic registration transaction that creates projects. Project identity stays
  independent from the display name.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  @type t :: %__MODULE__{}

  schema "projects" do
    field :name, :string

    belongs_to :workspace, SddOrchestrator.Accounts.PersonalWorkspace

    timestamps()
  end

  @doc false
  def changeset(project, attrs) do
    project
    |> cast(attrs, [:name, :workspace_id])
    |> validate_required([:name, :workspace_id])
    |> foreign_key_constraint(:workspace_id)
  end
end
