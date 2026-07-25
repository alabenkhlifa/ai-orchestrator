defmodule SddOrchestrator.Projects.ProjectOnboardingAttempt do
  @moduledoc """
  Short-lived, server-side onboarding workflow state for one in-flight project
  registration.

  This task owns the schema, the initial `status`, the `expires_at` window, and
  the `idempotency_key`. Later tasks fill in the rest of the flow: the repository
  picker writes `selected_repository`, the storage step writes `storage_mode` and
  `device_setup`, and the registration transaction sets `consumed_at` once the
  project commits. Abandoned attempts expire and are pruned; they hold no project
  or repository-connection state on their own.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  @type t :: %__MODULE__{}

  schema "project_onboarding_attempts" do
    field :idempotency_key, :string
    field :status, :string, default: "started"
    field :selected_repository, :map
    field :storage_mode, :string
    field :device_setup, :map
    field :expires_at, :utc_datetime
    field :consumed_at, :utc_datetime

    belongs_to :workspace, SddOrchestrator.Accounts.PersonalWorkspace

    timestamps()
  end

  @doc "Changeset for creating a fresh onboarding attempt."
  def create_changeset(attempt, attrs) do
    attempt
    |> cast(attrs, [:workspace_id, :idempotency_key, :status, :expires_at])
    |> validate_required([:workspace_id, :idempotency_key, :status, :expires_at])
    |> unique_constraint(:idempotency_key)
    |> foreign_key_constraint(:workspace_id)
  end

  @doc """
  Changeset that records the user's selected repository on the attempt. Stores
  only the approved repository metadata as a map and advances the status. The
  storage step and registration consume this later.
  """
  def select_repository_changeset(attempt, selected_repository) do
    attempt
    |> cast(%{selected_repository: selected_repository, status: "repository_selected"}, [
      :selected_repository,
      :status
    ])
    |> validate_required([:selected_repository])
  end
end
