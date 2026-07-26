defmodule SddOrchestrator.Accounts.Workspace do
  @moduledoc """
  The common logical owner of projects and repository connections.

  A workspace has one authoritative persistence boundary:

    * `"hosted"` roots live in the control-plane PostgreSQL database and have one
      `PersonalWorkspace` profile.
    * `"device"` roots live only in device persistence and have one
      `DeviceWorkspace` profile.

  The hosted database intentionally rejects device roots. This schema is also the
  logical contract used by the future device adapter without copying a device
  root or any device-authoritative project data into hosted persistence.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias SddOrchestrator.ProjectStorage.StorageMode

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  @type t :: %__MODULE__{}

  schema "workspaces" do
    field :kind, :string

    has_one :personal_workspace, SddOrchestrator.Accounts.PersonalWorkspace, foreign_key: :id

    has_many :projects, SddOrchestrator.Projects.Project
    has_many :repository_connections, SddOrchestrator.Projects.RepositoryConnection
    has_many :onboarding_attempts, SddOrchestrator.Projects.ProjectOnboardingAttempt

    timestamps()
  end

  @doc "Validates the common logical root. Persistence adapters enforce their own kind."
  def changeset(workspace, attrs) do
    workspace
    |> cast(attrs, [:kind])
    |> validate_required([:kind])
    |> validate_inclusion(:kind, StorageMode.values())
    |> check_constraint(:kind, name: :workspaces_hosted_kind_only)
  end

  @doc "Builds a device-local logical root without persisting it in the hosted database."
  @spec device_root(Ecto.UUID.t()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def device_root(id \\ Ecto.UUID.generate()) do
    %__MODULE__{id: id}
    |> changeset(%{kind: "device"})
    |> apply_action(:insert)
  end
end
