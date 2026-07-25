defmodule SddOrchestrator.Projects.RepositoryConnection do
  @moduledoc """
  The canonical link between a project and the GitHub repository it was created
  for.

  Repository identity is the provider's stable numeric id (`provider_repository_id`),
  not its owner, name, URL, or visibility — those are mutable access and display
  metadata refreshed after a validated read (owned by Task 8). A workspace links a
  repository at most once, enforced by the unique
  `(workspace_id, provider, provider_repository_id)` constraint, and a project has
  exactly one connection, enforced by the unique `project_id` constraint.

  Connection state (`connected` / `disconnected`) and revalidation are owned by
  Task 8; this task records the freshly confirmed connection at creation time.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  @type t :: %__MODULE__{}

  @repo_unique_index :repository_connections_workspace_provider_repo_index

  # Persisted connection states — the last confirmed result of a revalidation.
  # A transient provider outage is a display-only state and is never persisted, so
  # a temporary GitHub failure never overwrites the last confirmed state.
  @states ~w(connected disconnected)

  schema "repository_connections" do
    field :provider, :string, default: "github"
    field :provider_repository_id, :integer
    field :owner, :string
    field :name, :string
    field :full_name, :string
    field :html_url, :string
    field :visibility, :string
    field :private, :boolean
    field :organization, :string
    field :installation_id, :integer
    field :last_validated_at, :utc_datetime
    field :state, :string, default: "connected"

    belongs_to :project, SddOrchestrator.Projects.Project
    belongs_to :workspace, SddOrchestrator.Accounts.PersonalWorkspace

    timestamps()
  end

  @doc "Changeset for creating the connection inside the registration transaction."
  def create_changeset(connection, attrs) do
    connection
    |> cast(attrs, [
      :project_id,
      :workspace_id,
      :provider,
      :provider_repository_id,
      :owner,
      :name,
      :full_name,
      :html_url,
      :visibility,
      :private,
      :organization,
      :installation_id,
      :last_validated_at,
      :state
    ])
    |> validate_required([:project_id, :workspace_id, :provider, :provider_repository_id, :state])
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:workspace_id)
    |> unique_constraint([:workspace_id, :provider, :provider_repository_id],
      name: @repo_unique_index
    )
    |> unique_constraint(:project_id)
  end

  @doc """
  Updates the connection after a revalidation: the confirmed state, the validation
  timestamp, and any refreshed display metadata. Only `connected` and
  `disconnected` are persisted — a transient outage is never written here.
  """
  def status_changeset(connection, attrs) do
    connection
    |> cast(attrs, [
      :state,
      :last_validated_at,
      :owner,
      :name,
      :full_name,
      :html_url,
      :visibility,
      :private,
      :organization,
      :installation_id
    ])
    |> validate_required([:state, :last_validated_at])
    |> validate_inclusion(:state, @states)
  end

  @doc "The persisted connection states."
  def states, do: @states

  @doc "The name of the workspace/provider/repository-id unique index."
  def repo_unique_index, do: @repo_unique_index
end
