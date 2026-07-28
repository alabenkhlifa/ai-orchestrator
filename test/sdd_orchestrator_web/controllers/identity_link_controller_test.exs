defmodule SddOrchestratorWeb.IdentityLinkControllerTest do
  @moduledoc """
  Proof for the emailed passwordless-verification endpoint: a valid token returns
  the user to the linking confirmation and records the proof; every invalid,
  expired, or malformed link gets the same account-neutral response.
  """
  use SddOrchestratorWeb.ConnCase, async: true

  import SddOrchestrator.AccountsFixtures
  import SddOrchestrator.HostedAccessFixtures

  alias SddOrchestrator.IdentityLinking
  alias SddOrchestrator.IdentityLinking.IdentityMergeAttempt
  alias SddOrchestrator.Repo

  defp challenge do
    absorbed = account_fixture()
    hosted_identity_fixture(email: "owner@example.com")
    {:ok, attempt} = IdentityLinking.start_merge_attempt(absorbed, "owner@example.com")

    {:ok, %{challenge_id: cid, raw_token: token}} =
      IdentityLinking.request_passwordless_proof(attempt)

    %{attempt: attempt, challenge_id: cid, raw_token: token}
  end

  test "a valid verification link records the proof and returns to the confirmation", %{
    conn: conn
  } do
    %{attempt: attempt, challenge_id: cid, raw_token: token} = challenge()

    conn = get(conn, "/identity/link/verify?challenge=#{cid}&token=#{token}")

    assert redirected_to(conn) == "/identity/link/#{attempt.id}"

    assert %IdentityMergeAttempt{passwordless_proven_at: proven_at} =
             Repo.get(IdentityMergeAttempt, attempt.id)

    assert proven_at
  end

  test "an invalid token is account-neutral and changes nothing", %{conn: conn} do
    %{attempt: attempt, challenge_id: cid} = challenge()

    conn = get(conn, "/identity/link/verify?challenge=#{cid}&token=wrong-token")

    assert redirected_to(conn) == "/projects"
    assert is_nil(Repo.get(IdentityMergeAttempt, attempt.id).passwordless_proven_at)
  end

  test "a malformed link is account-neutral", %{conn: conn} do
    conn = get(conn, "/identity/link/verify")
    assert redirected_to(conn) == "/projects"
  end
end
