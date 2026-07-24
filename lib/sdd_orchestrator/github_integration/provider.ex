defmodule SddOrchestrator.GitHubIntegration.Provider do
  @moduledoc """
  Behaviour for the GitHub provider adapter.

  A single adapter owns every GitHub HTTP interaction so provider behavior,
  errors, and API-version pinning live in one place. `ReqProvider` is the real
  implementation; a deterministic fake implements the same behaviour in tests so
  ordinary CI never depends on a live GitHub account.

  This slice defines the OAuth/identity surface (authorization code exchange,
  user identity, token refresh). Installation and repository discovery callbacks
  are added by their owning tasks.
  """

  @typedoc "OAuth token set as returned by GitHub's token endpoint."
  @type token :: %{
          required(:access_token) => String.t(),
          optional(:refresh_token) => String.t() | nil,
          optional(:expires_in) => integer() | nil,
          optional(:refresh_token_expires_in) => integer() | nil,
          optional(:scope) => String.t() | nil
        }

  @typedoc "The authenticated GitHub user's stable identity."
  @type user :: %{
          required(:id) => integer(),
          required(:login) => String.t(),
          optional(:avatar_url) => String.t() | nil
        }

  @doc "Exchanges an authorization code (+ PKCE verifier) for an access token."
  @callback exchange_code(code :: String.t(), verifier :: String.t()) ::
              {:ok, token()} | {:error, term()}

  @doc "Resolves the authenticated user for an access token."
  @callback get_user(access_token :: String.t()) :: {:ok, user()} | {:error, term()}

  @doc "Refreshes an access token using a refresh token."
  @callback refresh_token(refresh_token :: String.t()) :: {:ok, token()} | {:error, term()}
end
