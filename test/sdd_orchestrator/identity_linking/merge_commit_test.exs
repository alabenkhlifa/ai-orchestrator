defmodule SddOrchestrator.IdentityLinking.MergeCommitTest do
  @moduledoc """
  Persistence and fault-injection proofs for the atomic merge commit:
  confirmation binding, idempotency, rollback with no partial state, stable
  identities, complete project movement, and GitHub sign-in resolving to the
  surviving workspace.
  """
  use SddOrchestrator.DataCase, async: true

  alias SddOrchestrator.Accounts
  alias SddOrchestrator.Accounts.{ExternalIdentity, GitHubCredential, GitHubIdentity}
  alias SddOrchestrator.IdentityLinking
  alias SddOrchestrator.IdentityLinking.IdentityMergeAttempt
  alias SddOrchestrator.Projects.{Project, RepositoryConnection}

  import SddOrchestrator.AccountsFixtures
  import SddOrchestrator.HostedAccessFixtures
  import SddOrchestrator.ProjectsFixtures

  # Builds a confirmed, conflict-free merge: a GitHub (absorbed) account with
  # projects and a session, and a passwordless (surviving) account with a project.
  defp confirmed_merge(email \\ "owner@example.com") do
    absorbed = account_fixture()
    absorbed_ws = workspace_fixture(absorbed)
    {:ok, session_token} = Accounts.create_session(absorbed)

    absorbed_project =
      registered_project(absorbed_ws,
        repository: repository_metadata(id: 900, name: "absorbed-repo"),
        name: "Absorbed Alpha"
      )

    %{account: surviving, hosted_identity: surviving_hi, personal_workspace: surviving_ws} =
      hosted_identity_fixture(email: email)

    surviving_project = project_fixture(surviving_ws, name: "Surviving Beta")

    {:ok, attempt} = IdentityLinking.start_merge_attempt(absorbed, email)

    {:ok, %{challenge_id: cid, raw_token: token}} =
      IdentityLinking.request_passwordless_proof(attempt)

    {:ok, proven} = IdentityLinking.submit_passwordless_proof(cid, token)
    {:ok, confirmed} = IdentityLinking.confirm_merge(proven)

    %{
      attempt: confirmed,
      absorbed: absorbed,
      absorbed_ws: absorbed_ws,
      absorbed_project: absorbed_project,
      session_token: session_token,
      surviving: surviving,
      surviving_hi: surviving_hi,
      surviving_ws: surviving_ws,
      surviving_project: surviving_project
    }
  end

  defp project_ids_in(workspace_id) do
    Repo.all(from p in Project, where: p.workspace_id == ^workspace_id, select: p.id)
    |> MapSet.new()
  end

  test "commits atomically: projects move, identity attaches, and stable ids are preserved" do
    ctx = confirmed_merge()

    assert {:ok, committed} = IdentityLinking.commit_merge(ctx.attempt)
    assert committed.status == "committed"
    assert committed.committed_at

    surviving_ids = project_ids_in(ctx.surviving_ws.id)
    # Complete data movement: every project now lives in the surviving workspace.
    assert MapSet.member?(surviving_ids, ctx.absorbed_project.id)
    assert MapSet.member?(surviving_ids, ctx.surviving_project.id)
    assert project_ids_in(ctx.absorbed_ws.id) == MapSet.new()

    # Stable identities: surviving account/workspace unchanged, project id unchanged.
    assert Repo.get(Project, ctx.absorbed_project.id).workspace_id == ctx.surviving_ws.id
    # Repository connection moved with its project.
    connection = Repo.get_by(RepositoryConnection, project_id: ctx.absorbed_project.id)
    assert connection.workspace_id == ctx.surviving_ws.id
    # Project-scoped hosted storage preserved.
    assert Repo.preload(Repo.get(Project, ctx.absorbed_project.id), :hosted_storage).hosted_storage
  end

  test "GitHub sign-in, credential, and session resolve to the surviving account" do
    ctx = confirmed_merge()
    github_user_id = ctx.absorbed.github_identity.github_user_id

    assert {:ok, _} = IdentityLinking.commit_merge(ctx.attempt)

    assert Accounts.get_account_by_github_user_id(github_user_id).id == ctx.surviving.id

    assert Repo.get_by(GitHubIdentity, github_user_id: github_user_id).account_id ==
             ctx.surviving.id

    assert Repo.get_by(GitHubCredential, account_id: ctx.surviving.id)

    # The initiating session now lands in the surviving account/workspace.
    assert {:ok, account} = Accounts.fetch_account_by_session_token(ctx.session_token)
    assert account.id == ctx.surviving.id

    # GitHub is recorded as a sign-in method on the surviving hosted identity.
    external =
      Repo.get_by(ExternalIdentity,
        hosted_identity_id: ctx.surviving_hi.id,
        provider: "github"
      )

    assert external.subject_key == Integer.to_string(github_user_id)
  end

  test "is idempotent: a second commit is a no-op with no duplicate attachment" do
    ctx = confirmed_merge()
    assert {:ok, committed} = IdentityLinking.commit_merge(ctx.attempt)
    assert {:ok, again} = IdentityLinking.commit_merge(committed)
    assert again.id == committed.id
    assert again.committed_at == committed.committed_at

    github_count =
      Repo.aggregate(
        from(e in ExternalIdentity,
          where: e.hosted_identity_id == ^ctx.surviving_hi.id and e.provider == "github"
        ),
        :count
      )

    assert github_count == 1
  end

  test "refuses to commit an unconfirmed attempt and moves nothing" do
    absorbed = account_fixture()
    absorbed_ws = workspace_fixture(absorbed)
    project = registered_project(absorbed_ws, name: "Absorbed Alpha")
    hosted_identity_fixture(email: "owner@example.com")
    {:ok, attempt} = IdentityLinking.start_merge_attempt(absorbed, "owner@example.com")

    {:ok, %{challenge_id: cid, raw_token: token}} =
      IdentityLinking.request_passwordless_proof(attempt)

    {:ok, proven} = IdentityLinking.submit_passwordless_proof(cid, token)

    assert {:error, :not_eligible} = IdentityLinking.commit_merge(proven)
    # Nothing moved: the project stays in the absorbed workspace.
    assert Repo.get(Project, project.id).workspace_id == absorbed_ws.id
  end

  test "rolls back with no partial state when a conflict appears before commit" do
    ctx = confirmed_merge()
    github_user_id = ctx.absorbed.github_identity.github_user_id

    # A colliding project appears in the surviving workspace after confirmation.
    project_fixture(ctx.surviving_ws, name: "Absorbed Alpha")

    assert {:error, :conflict} = IdentityLinking.commit_merge(ctx.attempt)

    # No partial state: absorbed project not moved, GitHub identity not re-pointed.
    assert Repo.get(Project, ctx.absorbed_project.id).workspace_id == ctx.absorbed_ws.id
    assert Accounts.get_account_by_github_user_id(github_user_id).id == ctx.absorbed.id
    assert is_nil(Repo.get(IdentityMergeAttempt, ctx.attempt.id).committed_at)
  end
end
