defmodule SddOrchestrator.Accounts.ApplicationSession do
  @moduledoc """
  A protected application session. Only the SHA-256 digest of the opaque browser
  token is stored, so a database read cannot reconstruct a usable cookie. A
  session is valid until its idle expiry (24h since last use), its absolute
  expiry (30d since creation), or an explicit revocation, whichever comes first.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  @derive {Inspect,
           only: [
             :id,
             :account_id,
             :idle_expires_at,
             :absolute_expires_at,
             :last_used_at,
             :revoked_at
           ]}
  schema "application_sessions" do
    field :token_digest, :string
    field :idle_expires_at, :utc_datetime
    field :absolute_expires_at, :utc_datetime
    field :last_used_at, :utc_datetime
    field :revoked_at, :utc_datetime

    belongs_to :account, SddOrchestrator.Accounts.Account

    timestamps()
  end

  @doc false
  def changeset(session, attrs) do
    session
    |> cast(attrs, [
      :token_digest,
      :idle_expires_at,
      :absolute_expires_at,
      :last_used_at,
      :revoked_at,
      :account_id
    ])
    |> validate_required([:token_digest, :idle_expires_at, :absolute_expires_at, :account_id])
    |> unique_constraint(:token_digest)
    |> foreign_key_constraint(:account_id)
  end
end
