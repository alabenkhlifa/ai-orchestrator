defmodule SddOrchestrator.Accounts.HostedSession do
  @moduledoc """
  One independently revocable hosted browser session.

  Only the digest of the opaque value inside the signed cookie is persisted.
  Device recognition is deliberately limited to coarse user-agent and operating
  system families; IP addresses and fingerprinting fields are not stored.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  @derive {Inspect,
           only: [
             :id,
             :hosted_identity_id,
             :user_agent_family,
             :os_family,
             :first_seen_at,
             :last_seen_at,
             :expires_at
           ]}

  @type t :: %__MODULE__{}

  schema "hosted_sessions" do
    field :token_digest, :binary, redact: true
    field :user_agent_family, :string
    field :os_family, :string
    field :first_seen_at, :utc_datetime
    field :last_seen_at, :utc_datetime
    field :expires_at, :utc_datetime

    belongs_to :hosted_identity, SddOrchestrator.Accounts.HostedIdentity

    timestamps()
  end

  @doc false
  def changeset(session, attrs) do
    session
    |> cast(attrs, [
      :token_digest,
      :user_agent_family,
      :os_family,
      :first_seen_at,
      :last_seen_at,
      :expires_at,
      :hosted_identity_id
    ])
    |> validate_required([
      :token_digest,
      :first_seen_at,
      :last_seen_at,
      :expires_at,
      :hosted_identity_id
    ])
    |> validate_length(:user_agent_family, max: 80)
    |> validate_length(:os_family, max: 80)
    |> unique_constraint(:token_digest)
    |> foreign_key_constraint(:hosted_identity_id)
  end
end
