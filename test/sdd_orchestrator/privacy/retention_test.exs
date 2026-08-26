defmodule SddOrchestrator.Privacy.RetentionTest do
  @moduledoc """
  Storage-limitation proof: the retention pruner deletes authorization and
  passwordless attempts, onboarding attempts, and application and hosted sessions
  past their configured windows, keeps still-live records, and is idempotent.
  """
  # `async: false`, like every other retention suite: `prune_all/1` now claims a
  # per-rule advisory lock, so a concurrently running module that also calls it
  # would make this one's exact-count assertions report a locked rule as zero.
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Accounts.{
    ApplicationSession,
    GitHubAuthorizationAttempt,
    HostedSession,
    MagicLinkAttempt
  }

  alias SddOrchestrator.Privacy.Retention
  alias SddOrchestrator.Projects
  alias SddOrchestrator.Projects.ProjectOnboardingAttempt

  alias SddOrchestrator.AccountsFixtures
  alias SddOrchestrator.HostedAccessFixtures
  alias SddOrchestrator.ProjectsFixtures

  @day 24 * 60 * 60

  defp ago(seconds),
    do: DateTime.add(DateTime.utc_now(), -seconds, :second) |> DateTime.truncate(:second)

  defp from_now(seconds),
    do: DateTime.add(DateTime.utc_now(), seconds, :second) |> DateTime.truncate(:second)

  defp insert_auth_attempt(inserted_at) do
    attempt =
      Repo.insert!(%GitHubAuthorizationAttempt{
        state_digest: "state-#{System.unique_integer([:positive])}",
        browser_nonce_digest: "nonce",
        pkce_verifier: "verifier",
        expires_at: from_now(600)
      })

    Repo.update_all(
      from(a in GitHubAuthorizationAttempt, where: a.id == ^attempt.id),
      set: [inserted_at: inserted_at]
    )

    attempt
  end

  defp insert_session(account, attrs) do
    Repo.insert!(
      struct(
        %ApplicationSession{
          account_id: account.id,
          token_digest: "digest-#{System.unique_integer([:positive])}",
          idle_expires_at: from_now(@day),
          absolute_expires_at: from_now(30 * @day),
          last_used_at: ago(60)
        },
        attrs
      )
    )
  end

  describe "authorization attempts" do
    test "deletes attempts older than 24 hours and keeps recent ones" do
      old = insert_auth_attempt(ago(@day + 3600))
      recent = insert_auth_attempt(ago(3600))

      assert %{authorization_attempts: 1} = Retention.prune_all()

      refute Repo.get(GitHubAuthorizationAttempt, old.id)
      assert Repo.get(GitHubAuthorizationAttempt, recent.id)
    end
  end

  describe "passwordless attempts" do
    test "deletes expired, consumed, and invalidated attempts after the grace period" do
      expired =
        HostedAccessFixtures.magic_link_attempt_fixture(%{
          expires_at: ago(@day + 60)
        }).attempt

      consumed = HostedAccessFixtures.magic_link_attempt_fixture().attempt
      invalidated = HostedAccessFixtures.magic_link_attempt_fixture().attempt
      active = HostedAccessFixtures.magic_link_attempt_fixture().attempt

      Repo.update_all(
        from(attempt in MagicLinkAttempt, where: attempt.id == ^consumed.id),
        set: [consumed_at: ago(@day + 60)]
      )

      Repo.update_all(
        from(attempt in MagicLinkAttempt, where: attempt.id == ^invalidated.id),
        set: [invalidated_at: ago(@day + 60)]
      )

      assert %{magic_link_attempts: 3} = Retention.prune_all()

      refute Repo.get(MagicLinkAttempt, expired.id)
      refute Repo.get(MagicLinkAttempt, consumed.id)
      refute Repo.get(MagicLinkAttempt, invalidated.id)
      assert Repo.get(MagicLinkAttempt, active.id)
    end
  end

  describe "onboarding attempts" do
    setup do
      account = AccountsFixtures.account_fixture()
      %{workspace: ProjectsFixtures.workspace_fixture(account)}
    end

    test "deletes an abandoned (expired, unconsumed) attempt", %{workspace: workspace} do
      {:ok, attempt} = Projects.start_onboarding_attempt(workspace)

      Repo.update_all(
        from(a in ProjectOnboardingAttempt, where: a.id == ^attempt.id),
        set: [expires_at: ago(60)]
      )

      assert %{onboarding_attempts: 1} = Retention.prune_all()
      refute Repo.get(ProjectOnboardingAttempt, attempt.id)
    end

    test "keeps a still-active attempt", %{workspace: workspace} do
      {:ok, attempt} = Projects.start_onboarding_attempt(workspace)

      assert %{onboarding_attempts: 0} = Retention.prune_all()
      assert Repo.get(ProjectOnboardingAttempt, attempt.id)
    end

    test "deletes a consumed attempt more than 24 hours old", %{workspace: workspace} do
      {:ok, attempt} = Projects.start_onboarding_attempt(workspace)

      Repo.update_all(
        from(a in ProjectOnboardingAttempt, where: a.id == ^attempt.id),
        set: [consumed_at: ago(@day + 3600)]
      )

      assert %{onboarding_attempts: 1} = Retention.prune_all()
      refute Repo.get(ProjectOnboardingAttempt, attempt.id)
    end
  end

  describe "sessions" do
    setup do
      %{account: AccountsFixtures.account_fixture()}
    end

    test "deletes sessions expired or revoked more than 24 hours ago", %{account: account} do
      idle_expired = insert_session(account, %{idle_expires_at: ago(@day + 60)})
      absolute_expired = insert_session(account, %{absolute_expires_at: ago(@day + 60)})
      revoked = insert_session(account, %{revoked_at: ago(@day + 60)})
      active = insert_session(account, %{})

      assert %{sessions: 3} = Retention.prune_all()

      refute Repo.get(ApplicationSession, idle_expired.id)
      refute Repo.get(ApplicationSession, absolute_expired.id)
      refute Repo.get(ApplicationSession, revoked.id)
      assert Repo.get(ApplicationSession, active.id)
    end
  end

  describe "hosted sessions" do
    test "deletes sessions expired past the grace period and keeps active sessions" do
      expired_result = HostedAccessFixtures.verified_hosted_session_fixture()
      active_result = HostedAccessFixtures.verified_hosted_session_fixture()

      Repo.update_all(
        from(session in HostedSession, where: session.id == ^expired_result.session.id),
        set: [expires_at: ago(@day + 60)]
      )

      assert %{hosted_sessions: 1} = Retention.prune_all()

      refute Repo.get(HostedSession, expired_result.session.id)
      assert Repo.get(HostedSession, active_result.session.id)
    end
  end

  test "re-running the pruner is idempotent" do
    insert_auth_attempt(ago(@day + 3600))

    assert %{authorization_attempts: 1} = Retention.prune_all()
    assert %{authorization_attempts: 0} = Retention.prune_all()
  end
end
