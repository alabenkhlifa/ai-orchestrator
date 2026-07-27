defmodule SddOrchestrator.Accounts.HostedIdentity do
  @moduledoc """
  The stable hosted identity restored by passwordless email or another
  previously linked sign-in method.

  Sign-in identifiers live in `ExternalIdentity`; this record keeps the hosted
  subject stable when a verified email's display spelling changes.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  @type t :: %__MODULE__{}

  schema "hosted_identities" do
    belongs_to :account, SddOrchestrator.Accounts.Account

    has_many :external_identities, SddOrchestrator.Accounts.ExternalIdentity
    has_many :hosted_sessions, SddOrchestrator.Accounts.HostedSession

    timestamps()
  end

  @doc false
  def changeset(identity, attrs) do
    identity
    |> cast(attrs, [:account_id])
    |> validate_required([:account_id])
    |> unique_constraint(:account_id)
    |> foreign_key_constraint(:account_id)
  end
end
