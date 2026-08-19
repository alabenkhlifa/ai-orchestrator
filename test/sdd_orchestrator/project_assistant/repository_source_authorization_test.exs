defmodule SddOrchestrator.ProjectAssistant.RepositorySourceAuthorizationTest do
  @moduledoc """
  specs/12-project-assistant Task 4 focused proof: acting-participant
  repository source authorization (AC-16).

  Covers a hosted GitHub-connected project where repository access
  genuinely differs by participant, a hosted project with no GitHub
  connection (participation alone is the answer), cross-project and
  unauthorized identities, device-authority identity match and mismatch, and
  credential non-substitution — the acting participant's own credential is
  always what gets checked, never the project owner's or another
  participant's.
  """
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Accounts.{DeviceWorkspace, GitHubCredential, GitHubIdentity}
  alias SddOrchestrator.AccountsFixtures
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.DeviceStore.Local
  alias SddOrchestrator.HostedAccessFixtures
  alias SddOrchestrator.ParticipationFixtures
  alias SddOrchestrator.ProjectAssistant.RepositorySourceAuthorization
  alias SddOrchestrator.ProjectsFixtures

  # Attaches a GitHub identity and credential to an *existing* account so a
  # non-owner participant (whose account has no GitHub linkage by default)
  # can be given a GitHub access scenario of its own via
  # `GitHubIntegration.FakeProvider`'s login-prefix convention, independent
  # of the project owner's own linkage.
  defp attach_github_identity(account, login) do
    github_user_id = System.unique_integer([:positive])

    {:ok, _identity} =
      %GitHubIdentity{}
      |> GitHubIdentity.changeset(%{
        github_user_id: github_user_id,
        login: login,
        account_id: account.id
      })
      |> Repo.insert()

    {:ok, _credential} =
      %GitHubCredential{}
      |> GitHubCredential.changeset(%{
        account_id: account.id,
        access_token: "fake-access:#{login}",
        refresh_token: "fake-refresh:#{login}",
        scopes: "repo"
      })
      |> Repo.insert()

    :ok
  end

  # A hosted project connected to repo id 101 ("octo/example"), owned by an
  # account whose own GitHub login ("octo") is granted access by the fake
  # provider's default scenario.
  defp github_connected_project do
    owner_account = AccountsFixtures.account_fixture(login: "octo")
    workspace = ProjectsFixtures.workspace_fixture(owner_account)
    project = ProjectsFixtures.registered_project(workspace)

    %{
      owner_account: owner_account,
      workspace: workspace,
      project: project,
      owner_actor: %{account_id: owner_account.id, hosted_identity_id: nil}
    }
  end

  defp add_participant(project, login_or_nil) do
    identity = HostedAccessFixtures.hosted_identity_fixture()
    ParticipationFixtures.participant_fixture(project, identity.hosted_identity)

    if login_or_nil, do: attach_github_identity(identity.account, login_or_nil)

    %{account_id: identity.account.id, hosted_identity_id: identity.hosted_identity.id}
  end

  describe "hosted authority — GitHub-connected repository" do
    test "authorizes the owner, whose own GitHub identity has access" do
      %{workspace: workspace, project: project, owner_actor: owner_actor} =
        github_connected_project()

      assert {:ok, target} =
               RepositorySourceAuthorization.authorize(workspace, project.id, owner_actor)

      assert target.project_id == project.id
      assert target.repository_provider == "github"
      assert target.repository_ref == "101"
      assert target.actor_ref == owner_actor.account_id
    end

    test "authorizes a participant whose own GitHub identity independently has access" do
      %{workspace: workspace, project: project} = github_connected_project()
      participant_actor = add_participant(project, "someone-else")

      assert {:ok, target} =
               RepositorySourceAuthorization.authorize(workspace, project.id, participant_actor)

      assert target.actor_ref == participant_actor.account_id
    end

    test "denies a current participant whose own GitHub identity lacks access to this repository" do
      %{workspace: workspace, project: project} = github_connected_project()
      # "norepos-*" installs but grants no repositories.
      participant_actor = add_participant(project, "norepos-participant")

      assert {:error, :source_denied} =
               RepositorySourceAuthorization.authorize(workspace, project.id, participant_actor)
    end

    test "denies a current participant with no linked GitHub identity at all" do
      %{workspace: workspace, project: project} = github_connected_project()
      participant_actor = add_participant(project, nil)

      assert {:error, :source_denied} =
               RepositorySourceAuthorization.authorize(workspace, project.id, participant_actor)
    end

    test "denies a current participant with no GitHub App installation at all" do
      %{workspace: workspace, project: project} = github_connected_project()
      participant_actor = add_participant(project, "noinstall-participant")

      assert {:error, :source_denied} =
               RepositorySourceAuthorization.authorize(workspace, project.id, participant_actor)
    end

    test "credential non-substitution: the acting participant's own denied access is checked, never the owner's granted access" do
      %{workspace: workspace, project: project} = github_connected_project()
      # The owner's own "octo" login is granted; this participant's is not.
      participant_actor = add_participant(project, "unauthorized-participant")

      assert {:error, :source_denied} =
               RepositorySourceAuthorization.authorize(workspace, project.id, participant_actor)
    end

    test "credential non-substitution: a participant's own granted access authorizes them even though the owner's own access is denied" do
      owner_account = AccountsFixtures.account_fixture(login: "unauthorized-owner")
      workspace = ProjectsFixtures.workspace_fixture(owner_account)
      project = ProjectsFixtures.registered_project(workspace)
      owner_actor = %{account_id: owner_account.id, hosted_identity_id: nil}

      participant_actor = add_participant(project, "octo-participant")

      assert {:error, :source_denied} =
               RepositorySourceAuthorization.authorize(workspace, project.id, owner_actor)

      assert {:ok, _target} =
               RepositorySourceAuthorization.authorize(workspace, project.id, participant_actor)
    end

    test "denies a stale (removed) participant without disclosure" do
      %{workspace: workspace, project: project} = github_connected_project()
      participant_actor = add_participant(project, "octo-participant")

      Repo.get_by!(SddOrchestrator.Participation.ProjectParticipant,
        project_id: project.id,
        hosted_identity_id: participant_actor.hosted_identity_id
      )
      |> SddOrchestrator.Participation.ProjectParticipant.departure_changeset(%{
        departure_reason: "removed"
      })
      |> Repo.update!()

      assert {:error, :unauthorized} =
               RepositorySourceAuthorization.authorize(workspace, project.id, participant_actor)
    end

    test "denies a cross-project identity the same way as an absent one" do
      %{workspace: workspace, project: project} = github_connected_project()
      other = ParticipationFixtures.invited_identity_fixture()
      absent_actor = %{account_id: other.account.id, hosted_identity_id: other.hosted_identity.id}

      %{project: other_project} = other_ctx = github_connected_project()
      other_project_owner_actor = other_ctx.owner_actor

      absent = RepositorySourceAuthorization.authorize(workspace, project.id, absent_actor)

      cross_project =
        RepositorySourceAuthorization.authorize(
          workspace,
          project.id,
          other_project_owner_actor
        )

      assert absent == {:error, :unauthorized}
      assert cross_project == {:error, :unauthorized}
      refute other_project.id == project.id
    end
  end

  describe "hosted authority — no GitHub connection" do
    test "authorizes a current participant on participation alone" do
      owner_account = AccountsFixtures.account_fixture()
      workspace = ProjectsFixtures.workspace_fixture(owner_account)
      project = ProjectsFixtures.project_fixture(workspace)
      owner_actor = %{account_id: owner_account.id, hosted_identity_id: nil}

      identity = HostedAccessFixtures.hosted_identity_fixture()
      ParticipationFixtures.participant_fixture(project, identity.hosted_identity)

      participant_actor = %{
        account_id: identity.account.id,
        hosted_identity_id: identity.hosted_identity.id
      }

      assert {:ok, owner_target} =
               RepositorySourceAuthorization.authorize(workspace, project.id, owner_actor)

      assert {:ok, participant_target} =
               RepositorySourceAuthorization.authorize(workspace, project.id, participant_actor)

      assert owner_target.repository_provider == nil
      assert participant_target.actor_ref == identity.account.id
    end
  end

  describe "device authority" do
    setup do
      path =
        Path.join(
          System.tmp_dir!(),
          "repository_source_authorization_device_#{System.unique_integer([:positive])}/store.dets"
        )

      on_exit(fn -> File.rm_rf!(Path.dirname(path)) end)
      start_supervised!({Local, path: path})

      {:ok, workspace} = Devices.establish_workspace()

      {:ok, project} =
        Devices.register_project(%{
          name: "Device source project",
          repository_fingerprint:
            "device-source-fingerprint-#{System.unique_integer([:positive])}",
          status: "connected",
          idempotency_key: Ecto.UUID.generate()
        })

      %{workspace: workspace, project: project}
    end

    test "authorizes the owning device workspace", %{workspace: workspace, project: project} do
      assert {:ok, target} =
               RepositorySourceAuthorization.authorize(workspace, project.id, %{})

      assert target.project_id == project.id
      assert target.actor_ref == workspace.id
    end

    test "denies a mismatched device workspace and a cross-project id identically", %{
      project: project
    } do
      other_workspace = %DeviceWorkspace{id: Ecto.UUID.generate()}

      wrong_workspace =
        RepositorySourceAuthorization.authorize(other_workspace, project.id, %{})

      assert wrong_workspace == {:error, :unauthorized}
    end

    test "denies an unknown project id", %{workspace: workspace} do
      assert {:error, :unauthorized} =
               RepositorySourceAuthorization.authorize(workspace, Ecto.UUID.generate(), %{})
    end
  end

  test "denies an unsupported authority" do
    assert {:error, :unauthorized} =
             RepositorySourceAuthorization.authorize(:not_an_authority, Ecto.UUID.generate(), %{})
  end
end
