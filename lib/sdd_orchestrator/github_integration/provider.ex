defmodule SddOrchestrator.GitHubIntegration.Provider do
  @moduledoc """
  Behaviour for the GitHub provider adapter.

  A single adapter owns every GitHub HTTP interaction so provider behavior,
  errors, and API-version pinning live in one place. `ReqProvider` is the real
  implementation; a deterministic fake implements the same behaviour in tests so
  ordinary CI never depends on a live GitHub account.

  This slice defines the OAuth/identity surface (authorization code exchange,
  user identity, token refresh) and the GitHub App repository-discovery surface
  (accessible installations, per-installation repositories, and pending
  installation requests). All list callbacks return the complete, already
  paginated result; deduplication across installations is the caller's concern.

  Provider errors are normalized to a small set of tagged atoms so callers stay
  independent of HTTP details:

    * `:unauthorized` — the user token is invalid or revoked.
    * `:rate_limited` — GitHub rate limit exhausted.
    * `:org_restricted` — organization policy (SSO, IP allow-list) blocks the
      read.
    * any other reason — treated as a generic provider failure.
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

  @typedoc "An `Orchestra-workflow` installation accessible to the user."
  @type installation :: %{
          required(:id) => integer(),
          required(:account_login) => String.t() | nil,
          required(:account_type) => String.t() | nil,
          required(:permissions) => %{optional(String.t()) => String.t()}
        }

  @typedoc "A repository returned under the granted access."
  @type repository :: %{
          required(:id) => integer(),
          required(:name) => String.t(),
          required(:owner) => String.t() | nil,
          required(:owner_type) => String.t() | nil,
          required(:full_name) => String.t() | nil,
          required(:private) => boolean(),
          required(:visibility) => String.t(),
          required(:html_url) => String.t() | nil,
          required(:organization) => String.t() | nil
        }

  @typedoc "A pending GitHub App installation request awaiting org approval."
  @type pending_request :: %{
          required(:id) => integer(),
          required(:account_login) => String.t() | nil,
          required(:requester_id) => integer() | nil
        }

  @doc "Exchanges an authorization code (+ PKCE verifier) for an access token."
  @callback exchange_code(code :: String.t(), verifier :: String.t()) ::
              {:ok, token()} | {:error, term()}

  @doc "Resolves the authenticated user for an access token."
  @callback get_user(access_token :: String.t()) :: {:ok, user()} | {:error, term()}

  @doc "Refreshes an access token using a refresh token."
  @callback refresh_token(refresh_token :: String.t()) :: {:ok, token()} | {:error, term()}

  @doc "Lists the app installations accessible to the authenticated user (paginated)."
  @callback list_user_installations(access_token :: String.t()) ::
              {:ok, [installation()]} | {:error, term()}

  @doc "Lists the repositories the user can access through one installation (paginated)."
  @callback list_installation_repositories(
              access_token :: String.t(),
              installation_id :: integer()
            ) :: {:ok, [repository()]} | {:error, term()}

  @doc """
  Lists installation requests awaiting organization approval.

  Uses an app JWT (not a user token); the caller matches `requester_id` against
  the authenticated user before treating a request as their own.
  """
  @callback list_pending_installation_requests() ::
              {:ok, [pending_request()]} | {:error, term()}
end
