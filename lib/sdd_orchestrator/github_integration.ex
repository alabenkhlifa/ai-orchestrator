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

  @doc """
  The public GitHub App installation URL for `Continue to GitHub`, carrying a
  one-time `state` value GitHub echoes back to the setup return.
  """
  def installation_url(state) do
    query = URI.encode_query(state: state)
    "https://github.com/apps/#{app_slug()}/installations/new?#{query}"
  end

  @doc """
  The exact repository permission scope onboarding relies on. Onboarding reads
  repository metadata only; no repository write permission is approved or used.
  """
  @spec approved_repository_permissions() :: %{String.t() => String.t()}
  def approved_repository_permissions do
    config()[:approved_repository_permissions] || %{"metadata" => "read"}
  end

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

  ## Repository-access discovery

  @typedoc "Normalized repository-access errors surfaced to the picker."
  @type access_error :: :unauthorized | :rate_limited | :org_restricted | :provider_failure

  @doc """
  Determines the user's `Orchestra-workflow` repository access.

  Returns:

    * `{:ok, :granted, installations}` — at least one accessible installation.
    * `{:ok, :pending, org_login}` — no installation, but the user has an
      organization installation request awaiting approval.
    * `{:ok, :none}` — no installation and no matching pending request; the grant
      screen is shown.
    * `{:error, reason}` — a normalized provider failure.

  A pending request counts only when its `requester_id` matches the authenticated
  GitHub user, so a pending request is never treated as granted access.
  """
  @spec check_repository_access(String.t(), integer()) ::
          {:ok, :granted, [Provider.installation()]}
          | {:ok, :pending, String.t() | nil}
          | {:ok, :none}
          | {:error, access_error()}
  def check_repository_access(access_token, github_user_id) do
    case provider().list_user_installations(access_token) do
      {:ok, []} -> pending_or_none(github_user_id)
      {:ok, installations} -> {:ok, :granted, installations}
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  defp pending_or_none(github_user_id) do
    case provider().list_pending_installation_requests() do
      {:ok, requests} ->
        case Enum.find(requests, &(&1.requester_id == github_user_id)) do
          nil -> {:ok, :none}
          request -> {:ok, :pending, request.account_login}
        end

      {:error, _reason} ->
        # Without a reliable pending-request read, fall back to the grant screen;
        # the user can still start the installation from there.
        {:ok, :none}
    end
  end

  @doc """
  Loads every repository accessible across the given installations, deduplicated
  by numeric repository id and ordered by owner/name for stable display. The
  catalog is fetched on demand and never persisted.
  """
  @spec list_accessible_repositories(String.t(), [Provider.installation()]) ::
          {:ok, [Provider.repository()]} | {:error, access_error()}
  def list_accessible_repositories(access_token, installations) do
    installations
    |> Enum.reduce_while({:ok, []}, fn installation, {:ok, acc} ->
      case provider().list_installation_repositories(access_token, installation.id) do
        {:ok, repos} -> {:cont, {:ok, acc ++ repos}}
        {:error, reason} -> {:halt, {:error, normalize_error(reason)}}
      end
    end)
    |> case do
      {:ok, repos} -> {:ok, repos |> dedupe_by_id() |> sort_for_display()}
      {:error, reason} -> {:error, reason}
    end
  end

  defp dedupe_by_id(repos) do
    {deduped, _seen} =
      Enum.reduce(repos, {[], MapSet.new()}, fn repo, {kept, seen} ->
        if MapSet.member?(seen, repo.id) do
          {kept, seen}
        else
          {[repo | kept], MapSet.put(seen, repo.id)}
        end
      end)

    Enum.reverse(deduped)
  end

  defp sort_for_display(repos) do
    Enum.sort_by(repos, fn repo ->
      {String.downcase(repo.owner || ""), String.downcase(repo.name || "")}
    end)
  end

  defp normalize_error(reason) when reason in [:unauthorized, :rate_limited, :org_restricted],
    do: reason

  defp normalize_error(_reason), do: :provider_failure
end
