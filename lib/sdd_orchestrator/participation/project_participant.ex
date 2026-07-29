defmodule SddOrchestrator.Participation.ProjectParticipant do
  @moduledoc """
  One project-scoped authorization attaching a stable hosted identity to the
  `Participant` role.

  This record is authorization only. It never carries the project presentation
  label, never changes project ownership, and never restores access after
  departure: removal and leave move the row to `departed`, and the approved
  retention rule may later erase its identity link while the historical profile
  remains.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias SddOrchestrator.Accounts.HostedIdentity
  alias SddOrchestrator.Projects.Project

  @roles ~w(participant)
  @states ~w(active departed)
  @departure_reasons ~w(removed left)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  @type t :: %__MODULE__{}

  schema "project_participants" do
    field :role, :string, default: "participant"
    field :state, :string, default: "active"
    field :joined_at, :utc_datetime
    field :departed_at, :utc_datetime
    field :departure_reason, :string

    belongs_to :project, Project
    belongs_to :hosted_identity, HostedIdentity

    timestamps()
  end

  @spec roles() :: [String.t()]
  def roles, do: @roles

  @spec states() :: [String.t()]
  def states, do: @states

  @spec departure_reasons() :: [String.t()]
  def departure_reasons, do: @departure_reasons

  @doc "Builds one active authorization for a proven hosted identity."
  def activation_changeset(participant, attrs) do
    participant
    |> cast(attrs, [:project_id, :hosted_identity_id, :role, :joined_at])
    |> put_change(:state, "active")
    |> put_default(:role, "participant")
    |> put_default(:joined_at, now())
    |> validate_required([:project_id, :hosted_identity_id, :role, :state, :joined_at])
    |> validate_inclusion(:role, @roles)
    |> apply_constraints()
  end

  @doc "Ends one active authorization without deleting its governed history."
  def departure_changeset(participant, attrs) do
    participant
    |> cast(attrs, [:departure_reason, :departed_at])
    |> put_change(:state, "departed")
    |> put_default(:departed_at, now())
    |> validate_required([:departure_reason, :departed_at])
    |> validate_inclusion(:departure_reason, @departure_reasons)
    |> apply_constraints()
  end

  @doc "Erases the authorization-to-identity link of a departed row."
  def identity_release_changeset(participant) do
    participant
    |> change(%{hosted_identity_id: nil})
    |> apply_constraints()
  end

  @spec active?(t()) :: boolean()
  def active?(%__MODULE__{state: "active"}), do: true
  def active?(%__MODULE__{}), do: false

  defp apply_constraints(changeset) do
    changeset
    |> validate_inclusion(:state, @states)
    |> unique_constraint(:hosted_identity_id,
      name: :project_participants_active_identity_index,
      message: "already participates in this project"
    )
    |> check_constraint(:state, name: :project_participants_state_shape)
    |> check_constraint(:role, name: :project_participants_role_allowed)
    |> check_constraint(:departure_reason,
      name: :project_participants_departure_reason_allowed
    )
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:hosted_identity_id)
  end

  defp put_default(changeset, field, default) do
    if is_nil(get_field(changeset, field)),
      do: put_change(changeset, field, default),
      else: changeset
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
