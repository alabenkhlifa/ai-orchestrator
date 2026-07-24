defmodule SddOrchestrator.GitHubIntegration.ReqProvider do
  @moduledoc """
  Real GitHub provider adapter built on `Req`.

  Requests pin the GitHub API version and JSON media type. Credentials are used
  only to make the call; they are never logged. Provider errors are normalized to
  tagged tuples so callers stay independent of HTTP details.
  """
  @behaviour SddOrchestrator.GitHubIntegration.Provider

  alias SddOrchestrator.GitHubIntegration

  @impl true
  def exchange_code(code, verifier) do
    cfg = GitHubIntegration.config()

    req(
      url: cfg[:token_url],
      method: :post,
      headers: [{"accept", "application/json"}],
      form: [
        client_id: cfg[:client_id],
        client_secret: cfg[:client_secret],
        code: code,
        redirect_uri: GitHubIntegration.callback_url(),
        code_verifier: verifier,
        grant_type: "authorization_code"
      ]
    )
    |> Req.request()
    |> case do
      {:ok, %{status: 200, body: %{"access_token" => access} = body}} when is_binary(access) ->
        {:ok, token_from_body(body)}

      {:ok, %{status: 200, body: %{"error" => error}}} ->
        {:error, {:oauth, error}}

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  @impl true
  def get_user(access_token) do
    case api_get("/user", access_token) do
      {:ok, %{status: 200, body: %{"id" => id, "login" => login} = body}} ->
        {:ok, %{id: id, login: login, avatar_url: body["avatar_url"]}}

      {:ok, %{status: 401}} ->
        {:error, :unauthorized}

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  @impl true
  def refresh_token(refresh_token) do
    cfg = GitHubIntegration.config()

    req(
      url: cfg[:token_url],
      method: :post,
      headers: [{"accept", "application/json"}],
      form: [
        client_id: cfg[:client_id],
        client_secret: cfg[:client_secret],
        grant_type: "refresh_token",
        refresh_token: refresh_token
      ]
    )
    |> Req.request()
    |> case do
      {:ok, %{status: 200, body: %{"access_token" => access} = body}} when is_binary(access) ->
        {:ok, token_from_body(body)}

      {:ok, %{status: 200, body: %{"error" => error}}} ->
        {:error, {:oauth, error}}

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  defp api_get(path, access_token) do
    cfg = GitHubIntegration.config()

    req(
      url: cfg[:api_base_url] <> path,
      headers: [
        {"accept", "application/vnd.github+json"},
        {"x-github-api-version", cfg[:api_version]},
        {"authorization", "Bearer " <> access_token}
      ]
    )
    |> Req.request()
  end

  # Merges test-supplied Req options (e.g. a Req.Test plug) so the adapter's
  # request/response contract can be exercised without a live GitHub.
  defp req(opts) do
    opts |> Keyword.merge(GitHubIntegration.config()[:req_options] || []) |> Req.new()
  end

  defp token_from_body(body) do
    %{
      access_token: body["access_token"],
      refresh_token: body["refresh_token"],
      expires_in: body["expires_in"],
      refresh_token_expires_in: body["refresh_token_expires_in"],
      scope: body["scope"]
    }
  end
end
