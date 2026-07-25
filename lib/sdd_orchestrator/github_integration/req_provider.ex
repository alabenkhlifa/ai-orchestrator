defmodule SddOrchestrator.GitHubIntegration.ReqProvider do
  @moduledoc """
  Real GitHub provider adapter built on `Req`.

  Requests pin the GitHub API version and JSON media type. Credentials are used
  only to make the call; they are never logged. Provider errors are normalized to
  tagged tuples so callers stay independent of HTTP details.
  """
  @behaviour SddOrchestrator.GitHubIntegration.Provider

  alias SddOrchestrator.GitHubIntegration
  alias SddOrchestrator.GitHubIntegration.AppJwt

  @per_page 100

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

  @impl true
  def list_user_installations(access_token) do
    paginate(
      GitHubIntegration.config()[:api_base_url] <> "/user/installations?per_page=#{@per_page}",
      access_token,
      "installations",
      &installation_from/1
    )
  end

  @impl true
  def list_installation_repositories(access_token, installation_id) do
    paginate(
      GitHubIntegration.config()[:api_base_url] <>
        "/user/installations/#{installation_id}/repositories?per_page=#{@per_page}",
      access_token,
      "repositories",
      &repository_from/1
    )
  end

  @impl true
  def list_pending_installation_requests do
    cfg = GitHubIntegration.config()

    case AppJwt.generate() do
      {:ok, jwt} ->
        req(
          url: cfg[:api_base_url] <> "/app/installation-requests?per_page=#{@per_page}",
          headers: [
            {"accept", "application/vnd.github+json"},
            {"x-github-api-version", cfg[:api_version]},
            {"authorization", "Bearer " <> jwt}
          ]
        )
        |> Req.request()
        |> case do
          {:ok, %{status: 200, body: body}} when is_list(body) ->
            {:ok, Enum.map(body, &pending_from/1)}

          {:ok, %{status: 200, body: %{"installation_requests" => list}}} when is_list(list) ->
            {:ok, Enum.map(list, &pending_from/1)}

          {:ok, %{status: status}} ->
            {:error, {:http, status}}

          {:error, reason} ->
            {:error, {:transport, reason}}
        end

      {:error, reason} ->
        {:error, {:app_jwt, reason}}
    end
  end

  # Follows GitHub's `Link` pagination until no `rel="next"` remains, mapping each
  # page's wrapped list (`installations`/`repositories`) with `mapper`.
  defp paginate(url, access_token, list_key, mapper, acc \\ []) do
    case api_get_url(url, access_token) do
      {:ok, %{status: 200, body: body} = resp} ->
        items = body |> Map.get(list_key, []) |> Enum.map(mapper)

        case next_link(resp) do
          nil -> {:ok, acc ++ items}
          next -> paginate(next, access_token, list_key, mapper, acc ++ items)
        end

      {:ok, %{status: 401}} ->
        {:error, :unauthorized}

      {:ok, %{status: 403} = resp} ->
        {:error, classify_403(resp)}

      {:ok, %{status: 429}} ->
        {:error, :rate_limited}

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  # A 403 with an exhausted primary rate limit is a rate limit; otherwise it is an
  # organization access restriction (SSO/IP allow-list) for our read-only scope.
  defp classify_403(resp) do
    case Req.Response.get_header(resp, "x-ratelimit-remaining") do
      ["0" | _] -> :rate_limited
      _ -> :org_restricted
    end
  end

  defp next_link(resp) do
    resp
    |> Req.Response.get_header("link")
    |> List.first()
    |> parse_next_link()
  end

  defp parse_next_link(nil), do: nil

  defp parse_next_link(header) when is_binary(header) do
    header
    |> String.split(",")
    |> Enum.find_value(fn part ->
      case Regex.run(~r/<([^>]+)>\s*;\s*rel="next"/, part) do
        [_, url] -> url
        _ -> nil
      end
    end)
  end

  defp installation_from(installation) do
    account = installation["account"] || %{}

    %{
      id: installation["id"],
      account_login: account["login"],
      account_type: account["type"],
      permissions: installation["permissions"] || %{}
    }
  end

  defp repository_from(repo) do
    owner = repo["owner"] || %{}
    owner_type = owner["type"]

    %{
      id: repo["id"],
      name: repo["name"],
      owner: owner["login"],
      owner_type: owner_type,
      full_name: repo["full_name"],
      private: repo["private"] == true,
      visibility: repo["visibility"] || if(repo["private"], do: "private", else: "public"),
      html_url: repo["html_url"],
      organization: (owner_type == "Organization" && owner["login"]) || nil
    }
  end

  defp pending_from(request) do
    requester = request["requester"] || %{}
    account = request["account"] || %{}

    %{
      id: request["id"],
      account_login: account["login"],
      requester_id: requester["id"]
    }
  end

  defp api_get(path, access_token) do
    api_get_url(GitHubIntegration.config()[:api_base_url] <> path, access_token)
  end

  defp api_get_url(url, access_token) do
    cfg = GitHubIntegration.config()

    req(
      url: url,
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
