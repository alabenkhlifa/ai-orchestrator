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
    # Where onboarding started, and its one owning shape:
    #   * "hosted" — GitHub onboarding while signed in; owns a hosted `workspace`.
    #   * "device" — accountless local onboarding; references an opaque device
    #     workspace and owns no hosted workspace. A verified hosted sign-in later
    #     records `hosted_prerequisite_workspace_id` to make hosted available.
    field :origin_kind, :string, default: "hosted"
    field :device_workspace_id, :binary_id
    field :hosted_prerequisite_workspace_id, :binary_id
    field :browser_flow_binding, :string

    field :idempotency_key, :string
    field :status, :string, default: "started"
    field :selected_repository, :map
    field :storage_mode, :string
    field :device_setup, :map
    field :expires_at, :utc_datetime
    field :consumed_at, :utc_datetime

    belongs_to :workspace, SddOrchestrator.Accounts.Workspace

    timestamps()
  end

  @doc "Changeset for creating a fresh hosted-origin onboarding attempt."
  def create_changeset(attempt, attrs) do
    attempt
    |> cast(attrs, [:workspace_id, :idempotency_key, :status, :expires_at])
    |> put_change(:origin_kind, "hosted")
    |> validate_required([:workspace_id, :idempotency_key, :status, :expires_at])
    |> unique_constraint(:idempotency_key)
    |> foreign_key_constraint(:workspace_id)
    |> check_constraint(:origin_kind, name: :onboarding_attempt_origin_shape)
  end

  @doc """
  Changeset for creating a fresh device-origin (accountless) onboarding attempt.

  It owns no hosted workspace; it references only the opaque device-workspace id
  and binds to the current browser flow so a later prerequisite return cannot be
  replayed against another browser.
  """
  def create_device_changeset(attempt, attrs) do
    attempt
    |> cast(attrs, [
      :device_workspace_id,
      :idempotency_key,
      :status,
      :expires_at,
      :browser_flow_binding
    ])
    |> put_change(:origin_kind, "device")
    |> validate_required([:device_workspace_id, :idempotency_key, :status, :expires_at])
    |> unique_constraint(:idempotency_key)
    |> check_constraint(:origin_kind, name: :onboarding_attempt_origin_shape)
  end

  @doc """
  Records the hosted workspace proven by a verified sign-in on a device-origin
  attempt, which makes hosted storage available. Never selects a mode or creates
  a project.
  """
  def hosted_prerequisite_changeset(attempt, hosted_workspace_id) do
    attempt
    |> cast(%{hosted_prerequisite_workspace_id: hosted_workspace_id}, [
      :hosted_prerequisite_workspace_id
    ])
    |> validate_required([:hosted_prerequisite_workspace_id])
    |> foreign_key_constraint(:hosted_prerequisite_workspace_id)
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

  @doc "Changeset that records the explicitly chosen storage mode on the attempt."
  def select_storage_changeset(attempt, storage_mode) do
    attempt
    |> cast(%{storage_mode: storage_mode}, [:storage_mode])
    |> validate_required([:storage_mode])
    |> validate_inclusion(
      :storage_mode,
      SddOrchestrator.ProjectStorage.StorageMode.values()
    )
  end

  @doc """
  Changeset that records the device-setup readiness state (the opaque receipt map
  supplied by the local-device boundary) on the attempt. Never selects a mode or
  creates a project.
  """
  def device_setup_changeset(attempt, device_setup) do
    attempt
    |> cast(%{device_setup: device_setup}, [:device_setup])
    |> validate_required([:device_setup])
  end

  @doc """
  Marks the attempt consumed once its project commits, so it is never reused and
  a retry resolves to the already-created project instead of a second one.
  """
  def consume_changeset(attempt) do
    change(attempt, %{
      status: "completed",
      consumed_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
  end
end
