defmodule SddOrchestrator.Accounts.GitHubAuthorizationAttempt do
  @moduledoc """
  Short-lived, single-use state for one GitHub authorization round trip: a digest
  of the random `state`, a digest of the browser-flow nonce that binds the return
  to the same browser, the encrypted PKCE verifier, the intended return route,
  the expiry, and the one-time consumption timestamp.

  Only digests of the `state` and nonce are stored so a database read cannot
  reconstruct a valid callback, and the PKCE verifier is encrypted at rest.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  @derive {Inspect, only: [:id, :expires_at, :consumed_at, :return_to]}
  schema "github_authorization_attempts" do
    field :state_digest, :string
    field :browser_nonce_digest, :string
    field :pkce_verifier, SddOrchestrator.Encrypted.Binary, redact: true
    field :return_to, :string
    field :expires_at, :utc_datetime
    field :consumed_at, :utc_datetime

    timestamps()
  end

  @doc false
  def changeset(attempt, attrs) do
    attempt
    |> cast(attrs, [
      :state_digest,
      :browser_nonce_digest,
      :pkce_verifier,
      :return_to,
      :expires_at,
      :consumed_at
    ])
    |> validate_required([:state_digest, :browser_nonce_digest, :pkce_verifier, :expires_at])
    |> unique_constraint(:state_digest)
  end
end
