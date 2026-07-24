defmodule SddOrchestrator.Accounts.GitHubIdentity do
  @moduledoc """
  The stable GitHub identity for an account: the provider's numeric user ID
  (the durable key), the current login, and an optional avatar URL. Email is
  neither requested nor stored by this slice.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  schema "github_identities" do
    field :github_user_id, :integer
    field :login, :string
    field :avatar_url, :string

    belongs_to :account, SddOrchestrator.Accounts.Account

    timestamps()
  end

  @doc false
  def changeset(identity, attrs) do
    identity
    |> cast(attrs, [:github_user_id, :login, :avatar_url, :account_id])
    |> validate_required([:github_user_id, :login, :account_id])
    |> unique_constraint(:github_user_id)
    |> foreign_key_constraint(:account_id)
  end
end
