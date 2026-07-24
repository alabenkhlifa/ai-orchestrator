defmodule SddOrchestrator.Accounts.Account do
  @moduledoc """
  The internal authenticated subject. Identity, credentials, sessions, and the
  personal workspace all hang off an `Account`; provider identifiers and display
  values are kept in separate associated records.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  @type t :: %__MODULE__{}

  schema "accounts" do
    field :state, Ecto.Enum, values: [:active, :disabled], default: :active

    has_one :github_identity, SddOrchestrator.Accounts.GitHubIdentity
    has_one :github_credential, SddOrchestrator.Accounts.GitHubCredential
    has_many :application_sessions, SddOrchestrator.Accounts.ApplicationSession

    timestamps()
  end

  @doc false
  def changeset(account, attrs) do
    account
    |> cast(attrs, [:state])
    |> validate_required([:state])
  end
end
