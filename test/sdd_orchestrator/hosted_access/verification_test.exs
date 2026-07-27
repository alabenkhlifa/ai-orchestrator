defmodule SddOrchestrator.HostedAccess.VerificationTest do
  use SddOrchestrator.DataCase, async: true

  alias SddOrchestrator.Accounts.{
    Account,
    ExternalIdentity,
    HostedIdentity,
    HostedSession,
    MagicLinkAttempt,
    PersonalWorkspace,
    Workspace
  }

  alias SddOrchestrator.HostedAccess
  alias SddOrchestrator.HostedAccess.SessionCookie
  alias SddOrchestrator.HostedAccessFixtures

  describe "verify_magic_link/3" do
    test "atomically consumes a valid attempt and establishes a protected hosted session" do
      %{attempt: attempt, raw_token: raw_token} =
        HostedAccessFixtures.magic_link_attempt_fixture(email: "Person@Example.com")

      assert {:ok, result} =
               HostedAccess.verify_magic_link(attempt.id, raw_token, %{
                 user_agent_family: "Firefox",
                 os_family: "Linux"
               })

      consumed_attempt = Repo.reload!(attempt)

      assert consumed_attempt.consumed_at != nil
      assert consumed_attempt.invalidated_at == nil
      assert result.external_identity.subject_key == "person@example.com"
      assert result.external_identity.display_identifier == "Person@Example.com"
      assert result.personal_workspace.workspace.kind == "hosted"

      assert result.session.hosted_identity_id == result.hosted_identity.id
      assert result.session.user_agent_family == "Firefox"
      assert result.session.os_family == "Linux"
      assert result.session.first_seen_at == result.session.last_seen_at

      assert DateTime.diff(
               result.session.expires_at,
               result.session.first_seen_at,
               :second
             ) == 2_592_000

      assert {:ok, digest} =
               SessionCookie.digest_from_signed(result.session_cookie.value)

      assert digest == result.session.token_digest
      assert SessionCookie.session_key() == :hosted_session_token

      assert SessionCookie.options() == [
               http_only: true,
               secure: true,
               same_site: "Lax",
               max_age: 2_592_000
             ]

      cookie_inspection = inspect(result.session_cookie)
      refute cookie_inspection =~ result.session_cookie.value

      session_inspection = inspect(result.session)
      refute session_inspection =~ Base.encode64(result.session.token_digest)

      assert Repo.aggregate(Account, :count) == 1
      assert Repo.aggregate(HostedIdentity, :count) == 1
      assert Repo.aggregate(ExternalIdentity, :count) == 1
      assert Repo.aggregate(Workspace, :count) == 1
      assert Repo.aggregate(PersonalWorkspace, :count) == 1
      assert Repo.aggregate(HostedSession, :count) == 1
    end

    test "restores an existing case-variant identity and stable workspace" do
      assert {:ok, existing} =
               HostedAccess.restore_or_create_identity("existing@example.com")

      %{attempt: attempt, raw_token: raw_token} =
        HostedAccessFixtures.magic_link_attempt_fixture(email: "EXISTING@EXAMPLE.COM")

      assert {:ok, restored} =
               HostedAccess.verify_magic_link(attempt.id, raw_token)

      assert restored.account.id == existing.account.id
      assert restored.hosted_identity.id == existing.hosted_identity.id
      assert restored.personal_workspace.id == existing.personal_workspace.id
      assert restored.external_identity.display_identifier == "EXISTING@EXAMPLE.COM"
      assert Repo.aggregate(Account, :count) == 1
      assert Repo.aggregate(HostedIdentity, :count) == 1
      assert Repo.aggregate(PersonalWorkspace, :count) == 1
      assert Repo.aggregate(HostedSession, :count) == 1
    end

    test "invalid, expired, invalidated, mismatched, and undelivered attempts fail identically" do
      valid =
        HostedAccessFixtures.magic_link_attempt_fixture(email: "valid@example.com")

      other =
        HostedAccessFixtures.magic_link_attempt_fixture(email: "other@example.com")

      expired =
        HostedAccessFixtures.magic_link_attempt_fixture(
          email: "expired@example.com",
          expires_at: DateTime.utc_now() |> DateTime.add(-1, :second)
        )

      invalidated =
        HostedAccessFixtures.magic_link_attempt_fixture(email: "invalidated@example.com")

      Repo.update_all(
        from(attempt in MagicLinkAttempt, where: attempt.id == ^invalidated.attempt.id),
        set: [invalidated_at: DateTime.utc_now() |> DateTime.truncate(:second)]
      )

      undelivered =
        HostedAccessFixtures.magic_link_attempt_fixture(
          email: "undelivered@example.com",
          delivery_status: "failed"
        )

      failures = [
        HostedAccess.verify_magic_link("not-an-id", valid.raw_token),
        HostedAccess.verify_magic_link(valid.attempt.id, "not-a-token"),
        HostedAccess.verify_magic_link(valid.attempt.id, other.raw_token),
        HostedAccess.verify_magic_link(expired.attempt.id, expired.raw_token),
        HostedAccess.verify_magic_link(invalidated.attempt.id, invalidated.raw_token),
        HostedAccess.verify_magic_link(undelivered.attempt.id, undelivered.raw_token)
      ]

      assert Enum.uniq(failures) == [{:error, :invalid_or_expired}]
      assert Repo.aggregate(Account, :count) == 0
      assert Repo.aggregate(HostedIdentity, :count) == 0
      assert Repo.aggregate(PersonalWorkspace, :count) == 0
      assert Repo.aggregate(HostedSession, :count) == 0
    end

    test "a consumed token cannot be replayed and a cookie signature cannot be tampered with" do
      %{attempt: attempt, raw_token: raw_token} =
        HostedAccessFixtures.magic_link_attempt_fixture(email: "replay@example.com")

      assert {:ok, result} =
               HostedAccess.verify_magic_link(attempt.id, raw_token)

      assert {:error, :invalid_or_expired} =
               HostedAccess.verify_magic_link(attempt.id, raw_token)

      assert :error =
               SessionCookie.digest_from_signed(result.session_cookie.value <> "tampered")

      assert Repo.aggregate(HostedSession, :count) == 1
      assert Repo.aggregate(HostedIdentity, :count) == 1
      assert Repo.aggregate(PersonalWorkspace, :count) == 1
    end

    test "concurrent consumption creates exactly one identity, workspace, and session" do
      %{attempt: attempt, raw_token: raw_token} =
        HostedAccessFixtures.magic_link_attempt_fixture(email: "race@example.com")

      results =
        1..2
        |> Task.async_stream(
          fn _request ->
            HostedAccess.verify_magic_link(attempt.id, raw_token)
          end,
          max_concurrency: 2,
          ordered: false
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.count(results, &match?({:ok, _result}, &1)) == 1
      assert Enum.count(results, &(&1 == {:error, :invalid_or_expired})) == 1
      assert Repo.aggregate(Account, :count) == 1
      assert Repo.aggregate(HostedIdentity, :count) == 1
      assert Repo.aggregate(ExternalIdentity, :count) == 1
      assert Repo.aggregate(PersonalWorkspace, :count) == 1
      assert Repo.aggregate(HostedSession, :count) == 1
    end

    test "session persistence failure rolls back identity, workspace, and consumption" do
      %{attempt: attempt, raw_token: raw_token} =
        HostedAccessFixtures.magic_link_attempt_fixture(email: "rollback@example.com")

      assert {:error, :invalid_or_expired} =
               HostedAccess.verify_magic_link(attempt.id, raw_token, %{
                 user_agent_family: String.duplicate("x", 81),
                 os_family: "Test OS"
               })

      assert Repo.reload!(attempt).consumed_at == nil
      assert Repo.aggregate(Account, :count) == 0
      assert Repo.aggregate(HostedIdentity, :count) == 0
      assert Repo.aggregate(ExternalIdentity, :count) == 0
      assert Repo.aggregate(Workspace, :count) == 0
      assert Repo.aggregate(PersonalWorkspace, :count) == 0
      assert Repo.aggregate(HostedSession, :count) == 0
    end

    test "different verified emails remain isolated across sessions" do
      one = HostedAccessFixtures.magic_link_attempt_fixture(email: "one@example.com")
      two = HostedAccessFixtures.magic_link_attempt_fixture(email: "two@example.com")

      assert {:ok, first} =
               HostedAccess.verify_magic_link(one.attempt.id, one.raw_token)

      assert {:ok, second} =
               HostedAccess.verify_magic_link(two.attempt.id, two.raw_token)

      refute first.account.id == second.account.id
      refute first.hosted_identity.id == second.hosted_identity.id
      refute first.personal_workspace.id == second.personal_workspace.id
      refute first.session.id == second.session.id
      assert Repo.aggregate(HostedSession, :count) == 2
    end
  end
end
