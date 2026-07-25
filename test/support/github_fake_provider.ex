defmodule SddOrchestrator.GitHubIntegration.FakeProvider do
  @moduledoc """
  Deterministic GitHub provider used in tests. No network access.

  Identity and outcomes are encoded in the authorization `code` (and, for the
  repository-discovery surface, in the account `login` embedded in the access
  token) so tests stay fully controlled:

    * `code == "provider-failure"` — the token exchange fails.
    * `code == "user-42"` (or any `user-<id>`) — resolves GitHub user id 42,
      login `user-42`. Signing in twice with the same code restores the same
      account.
    * any other code — a stable id derived from the code, login equal to the code.
    * a token minted from code `"no-user"` — user resolution fails.

  Repository-access scenarios are keyed off a prefix of the login carried in the
  access token (`"fake-access:" <> login`):

    * `"noinstall*"` / `"pending*"` — no accessible installation. `"pending*"`
      combined with an account whose GitHub id is `pending_requester_github_id/0`
      resolves to a pending organization request; everything else falls through
      to the grant screen.
    * `"norepos*"` — an installation exists but returns no repositories.
    * `"restricted*"` — repository listing is blocked by organization policy.
    * `"ratelimit*"` / `"unauthorized*"` / `"providerfail*"` — the matching
      provider error.
    * any other login — two installations (a personal and an organization one)
      whose repositories include a public repo, a private repo, an organization
      repo, and one repo shared across both installations (to exercise
      deduplication by numeric id).
  """
  @behaviour SddOrchestrator.GitHubIntegration.Provider

  @token_prefix "fake-access:"
  @refresh_prefix "fake-refresh:"

  # A pending installation request is emitted for this requester id so a
  # "pending*" account created with this GitHub id resolves to org-approval.
  @pending_requester_github_id 424_242

  @doc "The GitHub user id the fake's pending installation request is addressed to."
  def pending_requester_github_id, do: @pending_requester_github_id

  @impl true
  def exchange_code("provider-failure", _verifier), do: {:error, :provider_error}

  def exchange_code(code, _verifier) when is_binary(code) do
    {:ok,
     %{
       access_token: @token_prefix <> code,
       refresh_token: @refresh_prefix <> code,
       expires_in: 28_800,
       scope: "repo"
     }}
  end

  @impl true
  def get_user(@token_prefix <> "no-user"), do: {:error, :unauthorized}

  def get_user(@token_prefix <> code) do
    {id, login} = identity_for(code)
    {:ok, %{id: id, login: login, avatar_url: "https://avatars.example/#{login}.png"}}
  end

  def get_user(_), do: {:error, :unauthorized}

  @impl true
  def refresh_token(@refresh_prefix <> code) do
    {:ok,
     %{
       access_token: @token_prefix <> "refreshed-" <> code,
       refresh_token: @refresh_prefix <> code,
       expires_in: 28_800,
       scope: "repo"
     }}
  end

  def refresh_token(_), do: {:error, :invalid_grant}

  @impl true
  def list_user_installations(@token_prefix <> login) do
    case scenario(login) do
      :no_install -> {:ok, []}
      :unauthorized -> {:error, :unauthorized}
      :rate_limited -> {:error, :rate_limited}
      :provider_fail -> {:error, :provider_error}
      _ -> {:ok, installations_for(login)}
    end
  end

  def list_user_installations(_), do: {:error, :unauthorized}

  @impl true
  def list_installation_repositories(@token_prefix <> login, installation_id) do
    case scenario(login) do
      :restricted -> {:error, :org_restricted}
      :empty_repos -> {:ok, []}
      :ok -> {:ok, repositories_for(login, installation_id)}
      _ -> {:ok, []}
    end
  end

  def list_installation_repositories(_, _), do: {:error, :unauthorized}

  @impl true
  def list_pending_installation_requests do
    {:ok,
     [
       %{
         id: 9001,
         account_login: "acme-inc",
         requester_id: @pending_requester_github_id
       }
     ]}
  end

  defp scenario(login) do
    cond do
      String.starts_with?(login, "noinstall") -> :no_install
      String.starts_with?(login, "pending") -> :no_install
      String.starts_with?(login, "norepos") -> :empty_repos
      String.starts_with?(login, "restricted") -> :restricted
      String.starts_with?(login, "ratelimit") -> :rate_limited
      String.starts_with?(login, "unauthorized") -> :unauthorized
      String.starts_with?(login, "providerfail") -> :provider_fail
      true -> :ok
    end
  end

  # A personal installation (id 1) and an organization installation (id 2). Both
  # grant metadata:read only.
  defp installations_for(login) do
    [
      %{id: 1, account_login: login, account_type: "User", permissions: %{"metadata" => "read"}},
      %{
        id: 2,
        account_login: "acme",
        account_type: "Organization",
        permissions: %{"metadata" => "read"}
      }
    ]
  end

  # Installation 1 (personal): a public repo, a private repo, and the shared repo.
  # Installation 2 (org): the same shared repo (id 301, deduplicated) plus a
  # private org repo.
  defp repositories_for(login, 1) do
    [
      repo(101, "example", login, "User"),
      private_repo(102, "secret", login, "User"),
      repo(301, "shared", "acme", "Organization")
    ]
  end

  defp repositories_for(_login, 2) do
    [
      repo(301, "shared", "acme", "Organization"),
      private_repo(202, "platform", "acme", "Organization")
    ]
  end

  defp repositories_for(_login, _id), do: []

  defp repo(id, name, owner, owner_type) do
    %{
      id: id,
      name: name,
      owner: owner,
      owner_type: owner_type,
      full_name: "#{owner}/#{name}",
      private: false,
      visibility: "public",
      html_url: "https://github.com/#{owner}/#{name}",
      organization: (owner_type == "Organization" && owner) || nil
    }
  end

  defp private_repo(id, name, owner, owner_type) do
    %{repo(id, name, owner, owner_type) | private: true, visibility: "private"}
  end

  defp identity_for(code) do
    case Regex.run(~r/^user-(\d+)$/, code) do
      [_, id] -> {String.to_integer(id), code}
      _ -> {:erlang.phash2(code, 1_000_000_000), code}
    end
  end
end
