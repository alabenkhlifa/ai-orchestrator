defmodule SddOrchestrator.Privacy.RightsTest do
  @moduledoc """
  Data-subject-rights proof: the operator export gathers an account's data without
  exposing credentials, and erasure reaches application and passwordless copies.
  """
  use SddOrchestrator.DataCase, async: true

  alias SddOrchestrator.Accounts

  alias SddOrchestrator.Accounts.{
    Account,
    ApplicationSession,
    ExternalIdentity,
    GitHubCredential,
    GitHubIdentity,
    HostedIdentity,
    HostedSession,
    MagicLinkAttempt,
    PersonalWorkspace,
    Workspace
  }

  alias SddOrchestrator.Privacy.Rights
  alias SddOrchestrator.Projects.{Project, ProjectOnboardingAttempt, RepositoryConnection}
  alias SddOrchestrator.ProjectStorage.HostedProjectStorage

  alias SddOrchestrator.AccountsFixtures
  alias SddOrchestrator.HostedAccessFixtures
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

  describe "passwordless authentication data" do
    test "exports hosted identity, attempt, and coarse session data without credentials" do
      result =
        HostedAccessFixtures.verified_hosted_session_fixture(%{
          email: "Hosted.Person@Example.com",
          user_agent_family: "Firefox",
          os_family: "Linux"
        })

      assert {:ok, export} = Rights.export_account(result.hosted_identity.account_id)

      assert %{
               external_identities: [
                 %{
                   provider: "email",
                   display_identifier: "Hosted.Person@Example.com",
                   subject_key: "hosted.person@example.com"
                 }
               ]
             } = export.hosted_identity

      assert [
               %{
                 delivery_email: "Hosted.Person@Example.com",
                 delivery_status: "sent"
               }
             ] = export.magic_link_attempts

      assert [%{user_agent_family: "Firefox", os_family: "Linux"}] =
               export.hosted_sessions

      dump = inspect(export)
      refute dump =~ result.raw_token
      refute dump =~ Base.encode64(result.attempt.token_digest)
      refute dump =~ Base.encode64(result.session.token_digest)
      refute dump =~ "token_salt"
      refute dump =~ "token_digest"
    end

    test "account erasure removes hosted identity, methods, attempts, sessions, and workspace" do
      result =
        HostedAccessFixtures.verified_hosted_session_fixture(%{
          email: "erase-hosted@example.com"
        })

      assert {:ok, %{account_id: account_id}} =
               Rights.erase_account(result.hosted_identity.account_id)

      assert account_id == result.hosted_identity.account_id
      assert Repo.aggregate(Account, :count) == 0
      assert Repo.aggregate(HostedIdentity, :count) == 0
      assert Repo.aggregate(ExternalIdentity, :count) == 0
      assert Repo.aggregate(MagicLinkAttempt, :count) == 0
      assert Repo.aggregate(HostedSession, :count) == 0
      assert Repo.aggregate(PersonalWorkspace, :count) == 0
      assert Repo.aggregate(Workspace, :count) == 0
    end

    test "exports and erases attempts that never produced an account" do
      fixture =
        HostedAccessFixtures.magic_link_attempt_fixture(%{
          email: "Attempt.Only@Example.com"
        })

      assert {:ok, [%{delivery_email: "Attempt.Only@Example.com"}]} =
               Rights.export_passwordless_attempts(" attempt.only@example.COM ")

      assert {:ok, 1} =
               Rights.erase_passwordless_attempts(" attempt.only@example.COM ")

      refute Repo.get(MagicLinkAttempt, fixture.attempt.id)

      assert {:ok, []} =
               Rights.export_passwordless_attempts("attempt.only@example.com")
    end
  end
end
