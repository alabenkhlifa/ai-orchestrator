defmodule SddOrchestrator.Accounts.GitHubCredential do
  @moduledoc """
  A GitHub user's access and refresh tokens, encrypted at rest, with the
  provider-reported expiry and granted scopes. One credential per account. Raw
  tokens never leave the protected server boundary and are never rendered,
  logged, or handed to a worker.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  @derive {Inspect, only: [:id, :account_id, :token_expires_at, :scopes, :revoked_at]}
  schema "github_credentials" do
    field :access_token, SddOrchestrator.Encrypted.Binary, redact: true
    field :refresh_token, SddOrchestrator.Encrypted.Binary, redact: true
    field :token_expires_at, :utc_datetime
    field :scopes, :string
    field :revoked_at, :utc_datetime

    belongs_to :account, SddOrchestrator.Accounts.Account

    timestamps()
  end

  @doc false
  def changeset(credential, attrs) do
    credential
    |> cast(attrs, [
      :access_token,
      :refresh_token,
      :token_expires_at,
      :scopes,
      :revoked_at,
      :account_id
    ])
    |> validate_required([:access_token, :account_id])
    |> unique_constraint(:account_id)
    |> foreign_key_constraint(:account_id)
  end
end
