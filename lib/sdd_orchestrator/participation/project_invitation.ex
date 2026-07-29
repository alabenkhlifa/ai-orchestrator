defmodule SddOrchestrator.Participation.ProjectInvitation do
  @moduledoc """
  One project-scoped invitation addressed to an email address.

  An invitation grants no project authorization: it records who invited whom,
  the protected credential that proves the invited address, and the lifecycle
  state. The raw credential is never stored — only a salted digest that every
  terminal transition erases immediately — and the delivery address is stored
  encrypted alongside a runtime-keyed comparison digest used for uniqueness.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias SddOrchestrator.Accounts.Account
  alias SddOrchestrator.Encrypted
  alias SddOrchestrator.Projects.Project

  @statuses ~w(pending accepted declined canceled expired)
  @terminal_reasons ~w(accepted declined canceled expired replaced)
  @lifetime_seconds 7 * 24 * 60 * 60

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  @derive {Inspect,
           only: [:id, :project_id, :status, :expires_at, :terminal_reason, :credential_version]}

  @type t :: %__MODULE__{}

  schema "project_invitations" do
    field :email_digest, :binary, redact: true
    field :delivery_email, Encrypted.Binary, redact: true
    field :token_digest, :binary, redact: true
    field :token_salt, :binary, redact: true
    field :status, :string, default: "pending"
    field :expires_at, :utc_datetime
    field :terminal_at, :utc_datetime
    field :terminal_reason, :string
    field :credential_version, :integer, default: 1

    belongs_to :project, Project
    belongs_to :invited_by_account, Account

    timestamps()
  end

  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @spec terminal_reasons() :: [String.t()]
  def terminal_reasons, do: @terminal_reasons

  @spec lifetime_seconds() :: pos_integer()
  def lifetime_seconds, do: @lifetime_seconds

  @doc false
  def changeset(invitation, attrs) do
    invitation
    |> cast(attrs, [
      :project_id,
      :invited_by_account_id,
      :email_digest,
      :delivery_email,
      :token_digest,
      :token_salt,
      :expires_at,
      :credential_version
    ])
    |> put_change(:status, "pending")
    |> put_default(:credential_version, 1)
    |> validate_required([
      :project_id,
      :invited_by_account_id,
      :email_digest,
      :delivery_email,
      :token_digest,
      :token_salt,
      :expires_at,
      :credential_version
    ])
    |> validate_number(:credential_version, greater_than: 0)
    |> apply_constraints()
  end

  @doc """
  Ends one invitation, erasing its credential material in the same change.
  """
  def terminal_changeset(invitation, status, reason, at \\ nil) do
    invitation
    |> change(%{
      status: status,
      terminal_reason: reason,
      terminal_at: at || now(),
      token_digest: nil,
      token_salt: nil
    })
    |> validate_inclusion(:status, @statuses -- ["pending"])
    |> validate_inclusion(:terminal_reason, @terminal_reasons)
    |> apply_constraints()
  end

  @doc "Replaces the pending credential and restarts the seven-day lifetime."
  def credential_changeset(invitation, attrs) do
    invitation
    |> cast(attrs, [:token_digest, :token_salt, :expires_at])
    |> put_change(:status, "pending")
    |> put_change(:credential_version, (invitation.credential_version || 1) + 1)
    |> validate_required([:token_digest, :token_salt, :expires_at])
    |> apply_constraints()
  end

  @spec pending?(t()) :: boolean()
  def pending?(%__MODULE__{status: "pending"}), do: true
  def pending?(%__MODULE__{}), do: false

  @spec expired?(t(), DateTime.t()) :: boolean()
  def expired?(%__MODULE__{expires_at: expires_at}, now),
    do: DateTime.compare(now, expires_at) != :lt

  @doc "Returns the default expiry for a credential issued now."
  @spec default_expiry(DateTime.t()) :: DateTime.t()
  def default_expiry(now), do: DateTime.add(now, @lifetime_seconds, :second)

  defp apply_constraints(changeset) do
    changeset
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:email_digest,
      name: :project_invitations_pending_email_index,
      message: "already has a pending invitation for this project"
    )
    |> check_constraint(:status, name: :project_invitations_credential_shape)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:invited_by_account_id)
  end

  defp put_default(changeset, field, default) do
    if is_nil(get_field(changeset, field)),
      do: put_change(changeset, field, default),
      else: changeset
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
