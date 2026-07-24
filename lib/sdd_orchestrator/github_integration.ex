defmodule SddOrchestrator.GitHubIntegration do
  @moduledoc """
  GitHub integration context.

  Owns the configured provider adapter, the OAuth authorization URL (random
  `state` + PKCE `S256`), and the PKCE parameter helpers. HTTP calls delegate to
  the configured `Provider` implementation (real `Req` adapter in dev/prod, a
  deterministic fake in tests).
  """

  alias SddOrchestrator.GitHubIntegration.Provider

  @doc "Returns the configured GitHub provider adapter module."
  @spec provider() :: module()
  def provider do
    config()[:provider] || SddOrchestrator.GitHubIntegration.ReqProvider
  end

  @doc "The registered public GitHub App slug (e.g. `orchestra-workflow`)."
  def app_slug, do: config()[:app_slug]

  @doc "The deployment origin used to derive callback and setup URLs."
  def app_origin, do: config()[:app_origin]

  @doc "The exact OAuth callback URL, derived from the deployment origin."
  def callback_url, do: app_origin() <> "/auth/github/callback"

  @doc "The public GitHub App installation URL for `Continue to GitHub`."
  def installation_url, do: "https://github.com/apps/#{app_slug()}/installations/new"

  @doc """
  Builds the GitHub authorization URL for one attempt.

  `state` is the random opaque value bound to this browser flow; `code_challenge`
  is the base64url SHA-256 of the PKCE verifier.
  """
  @spec authorize_url(String.t(), String.t()) :: String.t()
  def authorize_url(state, code_challenge) do
    query =
      URI.encode_query(
        client_id: config()[:client_id],
        redirect_uri: callback_url(),
        state: state,
        code_challenge: code_challenge,
        code_challenge_method: "S256"
      )

    "#{config()[:authorize_url]}?#{query}"
  end

  @doc "Generates a PKCE verifier and its S256 challenge."
  @spec new_pkce() :: {verifier :: String.t(), challenge :: String.t()}
  def new_pkce do
    verifier = random_url_token(64)
    challenge = Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)
    {verifier, challenge}
  end

  @doc "Generates a random URL-safe token of `bytes` entropy."
  @spec random_url_token(pos_integer()) :: String.t()
  def random_url_token(bytes \\ 32) do
    bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  @doc "Runtime GitHub configuration (client id/secret, urls, api version)."
  def config, do: Application.get_env(:sdd_orchestrator, :github, [])

  ## Provider delegation

  @spec exchange_code(String.t(), String.t()) :: {:ok, Provider.token()} | {:error, term()}
  def exchange_code(code, verifier), do: provider().exchange_code(code, verifier)

  @spec get_user(String.t()) :: {:ok, Provider.user()} | {:error, term()}
  def get_user(access_token), do: provider().get_user(access_token)

  @spec refresh_token(String.t()) :: {:ok, Provider.token()} | {:error, term()}
  def refresh_token(refresh_token), do: provider().refresh_token(refresh_token)
end
