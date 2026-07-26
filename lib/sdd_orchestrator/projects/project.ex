defmodule SddOrchestrator.Projects.Project do
  @moduledoc """
  The SDD Orchestrator project: its stable identity, editable display name, and
  the registration attributes added by the project-confirmation task.

  Task 4 introduced the base read-model (identity, display name, workspace) so the
  catalog could list and route on real rows. This task extends the same schema
  additively with the canonical name comparison key (`name_key`), workspace-scoped
  case-insensitive uniqueness, the selected storage mode, lifecycle state, the
  one-to-one repository connection, and the hosted storage root. Project identity
  stays independent from the display name: renaming changes the display name and
  key without changing the id, repository connection, or storage.

  The display name is human-facing text — never a slug, URL, path, or key. The
  comparison key is derived with Unicode `NFKC` normalization followed by Unicode
  default case folding, so uniqueness is case-insensitive without rewriting the
  stored display value.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias SddOrchestrator.Projects.RepositoryConnection
  alias SddOrchestrator.ProjectStorage.HostedProjectStorage
  alias SddOrchestrator.ProjectStorage.StorageMode

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  @type t :: %__MODULE__{}

  @name_index :projects_workspace_id_name_key_index

  schema "projects" do
    field :name, :string
    field :name_key, :string
    field :storage_mode, :string
    field :lifecycle_state, :string, default: "active"

    belongs_to :workspace, SddOrchestrator.Accounts.Workspace
    belongs_to :onboarding_attempt, SddOrchestrator.Projects.ProjectOnboardingAttempt

    has_one :repository_connection, RepositoryConnection
    has_one :hosted_storage, HostedProjectStorage

    timestamps()
  end

  @doc """
  Base read-model changeset (Task 4 catalog). Derives the comparison key so every
  persisted project participates in workspace-scoped uniqueness even when created
  outside the registration transaction.
  """
  def changeset(project, attrs) do
    project
    |> cast(attrs, [:name, :workspace_id, :storage_mode])
    |> validate_name()
    |> put_name_key()
    |> put_default(:storage_mode, "hosted")
    |> validate_required([:name, :workspace_id, :name_key, :storage_mode])
    |> validate_inclusion(:storage_mode, StorageMode.values())
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:workspace_id, name: :projects_workspace_storage_mode_fkey)
    |> unique_constraint(:name, name: @name_index)
  end

  @doc """
  Changeset for the atomic registration transaction. Requires a validated display
  name, the confirmed workspace, and the explicitly selected storage mode; derives
  the comparison key and defaults the lifecycle state. A workspace-scoped name
  collision surfaces as an error on `:name` for inline feedback.
  """
  def registration_changeset(project, attrs) do
    project
    |> cast(attrs, [:name, :workspace_id, :storage_mode, :lifecycle_state, :onboarding_attempt_id])
    |> validate_name()
    |> put_name_key()
    |> put_default(:lifecycle_state, "active")
    |> validate_required([:name, :workspace_id, :name_key, :storage_mode, :lifecycle_state])
    |> validate_inclusion(:storage_mode, StorageMode.values())
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:workspace_id, name: :projects_workspace_storage_mode_fkey)
    |> unique_constraint(:name, name: @name_index)
  end

  @doc """
  Reusable rename operation: re-validates and re-derives the comparison key while
  keeping project and repository identity stable. Workspace-scoped uniqueness is
  enforced by the same constraint, reported inline on `:name`. Task 8 wires the
  post-creation rename control to this operation.
  """
  def rename_changeset(project, attrs) do
    project
    |> cast(attrs, [:name])
    |> validate_name()
    |> put_name_key()
    |> validate_required([:name, :name_key])
    |> unique_constraint(:name, name: @name_index)
  end

  @doc "The storage modes a project may be registered with."
  def storage_modes, do: StorageMode.values()

  @doc """
  Derives the canonical comparison key for a display name: trim boundary
  whitespace, apply Unicode `NFKC` normalization, then Unicode default case
  folding. Returns `nil` for a blank or missing name.
  """
  @spec name_key(String.t() | nil) :: String.t() | nil
  def name_key(nil), do: nil

  def name_key(name) when is_binary(name) do
    case String.trim(name) do
      "" ->
        nil

      trimmed ->
        trimmed
        |> :unicode.characters_to_nfkc_binary()
        |> String.downcase(:default)
    end
  end

  # Trim boundary whitespace, reject blank input and control characters, and keep
  # the user's display spelling and case. Never converts to a slug.
  defp validate_name(changeset) do
    case fetch_change(changeset, :name) do
      {:ok, name} when is_binary(name) ->
        trimmed = String.trim(name)

        cond do
          trimmed == "" ->
            changeset
            |> put_change(:name, trimmed)
            |> add_error(:name, "can't be blank")

          Regex.match?(~r/\p{Cc}/u, trimmed) ->
            changeset
            |> put_change(:name, trimmed)
            |> add_error(:name, "can't contain control characters")

          true ->
            put_change(changeset, :name, trimmed)
        end

      _ ->
        changeset
    end
  end

  defp put_name_key(changeset) do
    case get_field(changeset, :name) do
      name when is_binary(name) ->
        case name_key(name) do
          nil -> changeset
          key -> put_change(changeset, :name_key, key)
        end

      _ ->
        changeset
    end
  end

  defp put_default(changeset, field, default) do
    if is_nil(get_field(changeset, field)),
      do: put_change(changeset, field, default),
      else: changeset
  end
end
