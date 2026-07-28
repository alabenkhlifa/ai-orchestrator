defmodule SddOrchestrator.IdentityLinking.AuditNotificationTest do
  @moduledoc """
  Proofs for the security-audit trail, the surviving-identity merge notification,
  and account-neutral, secret-free behavior across success and failure paths.
  """
  use SddOrchestrator.DataCase, async: false

  import ExUnit.CaptureLog
  import Swoosh.TestAssertions

  import SddOrchestrator.AccountsFixtures
  import SddOrchestrator.HostedAccessFixtures

  alias SddOrchestrator.IdentityLinking

  setup do
    # The audit trail logs at :info; the test environment's default level is
    # :warning. Lower it for the duration so the trail is observable, then restore.
    previous = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous) end)
    :ok
  end

  defp detected(email) do
    absorbed = account_fixture()
    # The GitHub-authenticated account owns a personal workspace, as it would after
    # onboarding; the merge moves its projects out of it.
    SddOrchestrator.Accounts.get_or_create_personal_workspace(absorbed)
    hosted_identity_fixture(email: email)
    {:ok, attempt} = IdentityLinking.start_merge_attempt(absorbed, email)
    attempt
  end

  test "candidate detection logs an account-neutral audit event with no email" do
    absorbed = account_fixture()
    hosted_identity_fixture(email: "owner@example.com")

    log =
      capture_log(fn ->
        {:ok, _attempt} = IdentityLinking.start_merge_attempt(absorbed, "owner@example.com")
      end)

    assert log =~ "identity_linking_audit"
    assert log =~ "candidate_detected"
    refute log =~ "owner@example.com"
  end

  test "a no-match detection is audited account-neutrally with no email" do
    absorbed = account_fixture()

    log =
      capture_log(fn ->
        assert {:ok, :none} = IdentityLinking.start_merge_attempt(absorbed, "ghost@example.com")
      end)

    assert log =~ "candidate_skipped"
    assert log =~ "outcome=none"
    refute log =~ "ghost@example.com"
  end

  test "an ambiguous match is account-neutral and audited without disclosure" do
    absorbed = account_fixture()
    hosted_identity_fixture(email: "first.last@gmail.com")
    hosted_identity_fixture(email: "firstlast@gmail.com")

    log =
      capture_log(fn ->
        assert {:ok, :none} = IdentityLinking.start_merge_attempt(absorbed, "firstlast@gmail.com")
      end)

    assert log =~ "candidate_skipped"
    assert log =~ "outcome=ambiguous"
    refute log =~ "gmail.com"
  end

  test "the full success flow is audited and never logs the token or email" do
    attempt = detected("owner@example.com")

    {{result, token}, log} =
      with_log(fn ->
        {:ok, %{challenge_id: cid, raw_token: token}} =
          IdentityLinking.request_passwordless_proof(attempt)

        {:ok, proven} = IdentityLinking.submit_passwordless_proof(cid, token)
        {:ok, confirmed} = IdentityLinking.confirm_merge(proven)
        {IdentityLinking.commit_merge(confirmed), token}
      end)

    assert {:ok, _record} = result
    assert log =~ "proof_requested"
    assert log =~ "proof_succeeded"
    assert log =~ "merge_confirmed"
    assert log =~ "merge_committed"
    refute log =~ token
    refute log =~ "owner@example.com"
  end

  test "a failed proof returns the uniform account-neutral error and is audited" do
    attempt = detected("owner@example.com")
    {:ok, _} = IdentityLinking.request_passwordless_proof(attempt)

    log =
      capture_log(fn ->
        assert {:error, :invalid_or_expired} =
                 IdentityLinking.submit_passwordless_proof(Ecto.UUID.generate(), "wrong-token")
      end)

    assert log =~ "proof_failed"
  end

  test "send_passwordless_proof emails a single-use verification link to the candidate email" do
    attempt = detected("owner@example.com")

    assert :ok = IdentityLinking.send_passwordless_proof(attempt)

    assert_email_sent(fn email ->
      assert Enum.any?(email.to, fn {_name, address} -> address == "owner@example.com" end)
      assert email.text_body =~ "/identity/link/verify?"
      assert email.text_body =~ "challenge="
      assert email.text_body =~ "token="
    end)
  end

  test "a successful merge notifies the surviving identity" do
    attempt = detected("owner@example.com")

    {:ok, %{challenge_id: cid, raw_token: token}} =
      IdentityLinking.request_passwordless_proof(attempt)

    {:ok, proven} = IdentityLinking.submit_passwordless_proof(cid, token)
    {:ok, confirmed} = IdentityLinking.confirm_merge(proven)

    assert {:ok, _record} = IdentityLinking.commit_merge(confirmed)

    assert_email_sent(fn email ->
      assert email.subject =~ "linked"
      assert Enum.any?(email.to, fn {_name, address} -> address == "owner@example.com" end)
    end)
  end
end
