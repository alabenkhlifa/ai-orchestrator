defmodule SddOrchestrator.Privacy.RightsTest do
  @moduledoc """
  Data-subject-rights proof (Task 10, AC-42): the operator export gathers an
  account's data without exposing credentials, and erasure reaches every active copy
  by cascading from the account.
  """
  use SddOrchestrator.DataCase, async: true

  alias SddOrchestrator.Accounts

  alias SddOrchestrator.Accounts.{
    Account,
    ApplicationSession,
    GitHubCredential,
    GitHubIdentity,
    PersonalWorkspace,
    Workspace
  }

  alias SddOrchestrator.Privacy.Rights
  alias SddOrchestrator.Projects.{Project, ProjectOnboardingAttempt, RepositoryConnection}
  alias SddOrchestrator.ProjectStorage.HostedProjectStorage

  alias SddOrchestrator.AccountsFixtures
  alias SddOrchestrator.ProjectsFixtures

  defp full_account do
    account = AccountsFixtures.account_fixture(login: "octo")
    workspace = ProjectsFixtures.workspace_fixture(account)
    project = ProjectsFixtures.registered_project(workspace, name: "Roadmap")

    Repo.insert!(%ApplicationSession{
      account_id: account.id,
      token_digest: "digest",
      idle_expires_at:
        DateTime.add(DateTime.utc_now(), 3600, :second) |> DateTime.truncate(:second),
      absolute_expires_at:
        DateTime.add(DateTime.utc_now(), 30 * 86_400, :second) |> DateTime.truncate(:second),
      last_used_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })

    %{account: account, project: project}
  end

  describe "export_account/1" do
    test "gathers the account's data without exposing credentials" do
      %{account: account} = full_account()
      credential = Accounts.get_github_credential(account.id)

      assert {:ok, export} = Rights.export_account(account.id)

      assert export.github_identity.login == "octo"
      assert [%{name: "Roadmap", repository: %{full_name: "octo/example"}}] = export.projects
      assert length(export.sessions) == 1

      # No access token, refresh token, PKCE verifier, or session digest is exported.
      dump = inspect(export)
      refute dump =~ credential.access_token
      refute dump =~ "fake-refresh"
      refute dump =~ "digest"
    end

    test "returns not_found for an unknown account" do
      assert {:error, :not_found} = Rights.export_account(Ecto.UUID.generate())
    end
  end

  describe "erase_account/1" do
    test "deletes the account and every record that cascades from it" do
      %{account: account} = full_account()

      assert {:ok, %{account_id: id}} = Rights.erase_account(account.id)
      assert id == account.id

      assert Repo.aggregate(Account, :count) == 0
      assert Repo.aggregate(GitHubIdentity, :count) == 0
      assert Repo.aggregate(GitHubCredential, :count) == 0
      assert Repo.aggregate(ApplicationSession, :count) == 0
      assert Repo.aggregate(PersonalWorkspace, :count) == 0
      assert Repo.aggregate(Workspace, :count) == 0
      assert Repo.aggregate(Project, :count) == 0
      assert Repo.aggregate(RepositoryConnection, :count) == 0
      assert Repo.aggregate(HostedProjectStorage, :count) == 0
      assert Repo.aggregate(ProjectOnboardingAttempt, :count) == 0
    end

    test "returns not_found for an unknown account" do
      assert {:error, :not_found} = Rights.erase_account(Ecto.UUID.generate())
    end
  end
end
