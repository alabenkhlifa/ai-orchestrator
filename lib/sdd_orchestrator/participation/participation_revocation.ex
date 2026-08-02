defmodule SddOrchestrator.Participation.ParticipationRevocation do
  @moduledoc """
  One versioned handoff telling approved consumers that a participation ended.

  The record is a producer contract, not a command: it names the project, the
  former participant, the immutable owner who becomes the fallback, the last
  accepted project display name, why and when it happened, and the contract
  version. It carries no feature, question, review, run, or notification state,
  because this specification never mutates a consumer's records.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias SddOrchestrator.Accounts.{Account, HostedIdentity}
  alias SddOrchestrator.Participation.ProjectParticipant
  alias SddOrchestrator.Projects.Project

  @contract_version 1
  @reasons ~w(removed left)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  @type t :: %__MODULE__{}

  schema "participation_revocations" do
    field :contract_version, :integer, default: @contract_version
    field :last_display_name, :string
    field :reason, :string
    field :occurred_at, :utc_datetime
    field :claimed_at, :utc_datetime
    field :acknowledged_at, :utc_datetime
    field :consumer_ref, :string

    belongs_to :project, Project
    belongs_to :project_participant, ProjectParticipant
    belongs_to :former_hosted_identity, HostedIdentity
    belongs_to :former_account, Account
    belongs_to :owner_account, Account

    timestamps()
  end

  @spec contract_version() :: pos_integer()
  def contract_version, do: @contract_version

  @spec reasons() :: [String.t()]
  def reasons, do: @reasons

  @doc false
  def changeset(revocation, attrs) do
    revocation
    |> cast(attrs, [
      :contract_version,
      :project_id,
      :project_participant_id,
      :former_hosted_identity_id,
      :former_account_id,
      :owner_account_id,
      :last_display_name,
      :reason,
      :occurred_at
    ])
    |> put_default(:contract_version, @contract_version)
    |> validate_required([
      :contract_version,
      :project_id,
      :project_participant_id,
      :owner_account_id,
      :reason,
      :occurred_at
    ])
    |> validate_inclusion(:reason, @reasons)
    |> validate_number(:contract_version, greater_than: 0)
    |> validate_length(:last_display_name, max: 80, count: :bytes)
    |> unique_constraint(:project_participant_id,
      name: :participation_revocations_participation_index,
      message: "already has a recorded handoff"
    )
    |> check_constraint(:reason, name: :participation_revocations_reason_allowed)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:project_participant_id)
    |> foreign_key_constraint(:owner_account_id)
  end

  @doc "Marks one handoff as claimed by a consumer."
  def claim_changeset(revocation, claimed_at),
    do: change(revocation, %{claimed_at: claimed_at})

  @doc "Releases the former-participant routing links while preserving the handoff."
  def identity_release_changeset(revocation) do
    change(revocation, %{
      former_hosted_identity_id: nil,
      former_account_id: nil
    })
  end

  @doc "Records that a consumer committed its own handling of one handoff."
  def acknowledge_changeset(revocation, consumer_ref, acknowledged_at) do
    revocation
    |> identity_release_changeset()
    |> change(%{
      consumer_ref: consumer_ref,
      acknowledged_at: acknowledged_at,
      claimed_at: revocation.claimed_at || acknowledged_at
    })
    |> validate_required([:consumer_ref, :acknowledged_at])
    |> validate_length(:consumer_ref, max: 128, count: :bytes)
    |> check_constraint(:acknowledged_at, name: :participation_revocations_ack_shape)
  end

  @spec acknowledged?(t()) :: boolean()
  def acknowledged?(%__MODULE__{acknowledged_at: nil}), do: false
  def acknowledged?(%__MODULE__{}), do: true

  defp put_default(changeset, field, default) do
    if is_nil(get_field(changeset, field)),
      do: put_change(changeset, field, default),
      else: changeset
  end
end
