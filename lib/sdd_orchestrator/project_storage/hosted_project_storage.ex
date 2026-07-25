defmodule SddOrchestrator.ProjectStorage.HostedProjectStorage do
  @moduledoc """
  The hosted storage root for a project whose work is saved "In my SDD Orchestrator
  account".

  It is initialized in the same database transaction as its project (see
  `SddOrchestrator.ProjectStorage.Hosted`), so a project never commits without its
  hosted storage and hosted storage never exists without its project. The `root`
  is an internal storage key derived from the project id; it is not a filesystem
  path or a repository location, and repository content stays on GitHub.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  @type t :: %__MODULE__{}

  schema "hosted_project_storages" do
    field :root, :string
    field :state, :string, default: "ready"

    belongs_to :project, SddOrchestrator.Projects.Project

    timestamps()
  end

  @doc "Changeset for initializing hosted storage alongside its project."
  def create_changeset(storage, attrs) do
    storage
    |> cast(attrs, [:project_id, :root, :state])
    |> validate_required([:project_id, :root, :state])
    |> foreign_key_constraint(:project_id)
    |> unique_constraint(:project_id)
  end
end
