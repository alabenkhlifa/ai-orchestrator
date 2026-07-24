defmodule SddOrchestrator.GitHubIntegration.FakeProvider do
  @moduledoc """
  Deterministic GitHub provider used in tests. No network access.

  Identity and outcomes are encoded in the authorization `code` so tests stay
  fully controlled:

    * `code == "provider-failure"` — the token exchange fails.
    * `code == "user-42"` (or any `user-<id>`) — resolves GitHub user id 42,
      login `user-42`. Signing in twice with the same code restores the same
      account.
    * any other code — a stable id derived from the code, login equal to the code.
    * a token minted from code `"no-user"` — user resolution fails.
  """
  @behaviour SddOrchestrator.GitHubIntegration.Provider

  @token_prefix "fake-access:"
  @refresh_prefix "fake-refresh:"

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

  defp identity_for(code) do
    case Regex.run(~r/^user-(\d+)$/, code) do
      [_, id] -> {String.to_integer(id), code}
      _ -> {:erlang.phash2(code, 1_000_000_000), code}
    end
  end
end
