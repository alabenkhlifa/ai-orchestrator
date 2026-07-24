defmodule SddOrchestrator.AccountsFixtures do
  @moduledoc "Test fixtures for accounts, identities, credentials, and sessions."

  alias SddOrchestrator.Accounts.{Account, GitHubCredential, GitHubIdentity}
  alias SddOrchestrator.Repo

  @doc "Creates an account with a GitHub identity and an encrypted credential."
  def account_fixture(attrs \\ %{}) do
    github_user_id = attrs[:github_user_id] || System.unique_integer([:positive])
    login = attrs[:login] || "user-#{github_user_id}"

    {:ok, account} =
      %Account{} |> Account.changeset(%{state: :active}) |> Repo.insert()

    {:ok, identity} =
      %GitHubIdentity{}
      |> GitHubIdentity.changeset(%{
        github_user_id: github_user_id,
        login: login,
        avatar_url: "https://avatars.example/#{login}.png",
        account_id: account.id
      })
      |> Repo.insert()

    {:ok, _credential} =
      %GitHubCredential{}
      |> GitHubCredential.changeset(%{
        account_id: account.id,
        access_token: attrs[:access_token] || "fake-access:#{login}",
        refresh_token: attrs[:refresh_token] || "fake-refresh:#{login}",
        scopes: "repo"
      })
      |> Repo.insert()

    %{account | github_identity: identity}
  end
end
