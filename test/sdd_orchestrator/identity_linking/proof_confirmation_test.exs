defmodule SddOrchestrator.IdentityLinking.ProofConfirmationTest do
  @moduledoc """
  Security proofs for the fresh two-method proof and explicit confirmation gate:
  successful proof, invalid, expired, mismatched, replayed, cancelled, and
  unconfirmed attempts. Only a freshly proven and explicitly confirmed attempt
  with a clear preflight is commit-eligible; an email match alone never is.
  """
  use SddOrchestrator.DataCase, async: true

  alias SddOrchestrator.IdentityLinking
  alias SddOrchestrator.IdentityLinking.IdentityMergeAttempt

  import SddOrchestrator.AccountsFixtures
  import SddOrchestrator.HostedAccessFixtures
  import SddOrchestrator.ProjectsFixtures

  defp scenario(email \\ "owner@example.com") do
    absorbed = account_fixture()
    %{personal_workspace: surviving_ws} = hosted_identity_fixture(email: email)
    {:ok, attempt} = IdentityLinking.start_merge_attempt(absorbed, email)
    absorbed_ws = workspace_fixture(absorbed)
    %{absorbed: absorbed, attempt: attempt, surviving_ws: surviving_ws, absorbed_ws: absorbed_ws}
  end

  defp reload(attempt), do: Repo.get!(IdentityMergeAttempt, attempt.id)

  describe "request_passwordless_proof/1" do
    test "issues a challenge for the candidate email without exposing the raw token on the record" do
      %{attempt: attempt} = scenario("owner@example.com")

      assert {:ok, %{challenge_id: challenge_id, raw_token: raw_token, delivery_email: email}} =
               IdentityLinking.request_passwordless_proof(attempt)

      assert email == "owner@example.com"
      assert {:ok, decoded} = Base.url_decode64(raw_token, padding: false)
      assert byte_size(decoded) == 32

      stored = reload(attempt)
      assert stored.passwordless_challenge_id == challenge_id
      assert is_binary(stored.passwordless_proof_digest)
      refute stored.passwordless_proof_digest == raw_token
      assert is_nil(stored.passwordless_proven_at)
    end
  end

  describe "submit_passwordless_proof/2" do
    test "records a fresh proof for a valid token and clears the single-use challenge" do
      %{attempt: attempt} = scenario()

      {:ok, %{challenge_id: challenge_id, raw_token: raw_token}} =
        IdentityLinking.request_passwordless_proof(attempt)

      assert {:ok, proven} = IdentityLinking.submit_passwordless_proof(challenge_id, raw_token)
      assert proven.passwordless_proven_at
      assert proven.status == "awaiting_confirmation"
      assert is_nil(proven.passwordless_proof_digest)
    end

    test "rejects an invalid token" do
      %{attempt: attempt} = scenario()
      {:ok, %{challenge_id: challenge_id}} = IdentityLinking.request_passwordless_proof(attempt)

      wrong = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

      assert {:error, :invalid_or_expired} =
               IdentityLinking.submit_passwordless_proof(challenge_id, wrong)

      assert is_nil(reload(attempt).passwordless_proven_at)
    end

    test "rejects a malformed (wrong-shape) token" do
      %{attempt: attempt} = scenario()
      {:ok, %{challenge_id: challenge_id}} = IdentityLinking.request_passwordless_proof(attempt)

      assert {:error, :invalid_or_expired} =
               IdentityLinking.submit_passwordless_proof(challenge_id, "short")

      assert {:error, :invalid_or_expired} =
               IdentityLinking.submit_passwordless_proof(challenge_id, nil)
    end

    test "rejects an expired challenge" do
      %{attempt: attempt} = scenario()

      {:ok, %{challenge_id: challenge_id, raw_token: raw_token}} =
        IdentityLinking.request_passwordless_proof(attempt)

      past = DateTime.add(DateTime.utc_now(), -60, :second) |> DateTime.truncate(:second)

      attempt
      |> reload()
      |> Ecto.Changeset.change(passwordless_proof_expires_at: past)
      |> Repo.update!()

      assert {:error, :invalid_or_expired} =
               IdentityLinking.submit_passwordless_proof(challenge_id, raw_token)
    end

    test "rejects a mismatched challenge id" do
      %{attempt: attempt} = scenario()
      {:ok, %{raw_token: raw_token}} = IdentityLinking.request_passwordless_proof(attempt)

      assert {:error, :invalid_or_expired} =
               IdentityLinking.submit_passwordless_proof(Ecto.UUID.generate(), raw_token)
    end

    test "rejects a replayed token after a successful proof" do
      %{attempt: attempt} = scenario()

      {:ok, %{challenge_id: challenge_id, raw_token: raw_token}} =
        IdentityLinking.request_passwordless_proof(attempt)

      assert {:ok, _} = IdentityLinking.submit_passwordless_proof(challenge_id, raw_token)

      assert {:error, :invalid_or_expired} =
               IdentityLinking.submit_passwordless_proof(challenge_id, raw_token)
    end

    test "rejects a proof for a cancelled (aborted) attempt" do
      %{attempt: attempt} = scenario()

      {:ok, %{challenge_id: challenge_id, raw_token: raw_token}} =
        IdentityLinking.request_passwordless_proof(attempt)

      {:ok, _} = IdentityLinking.abort_merge_attempt(reload(attempt))

      assert {:error, :invalid_or_expired} =
               IdentityLinking.submit_passwordless_proof(challenge_id, raw_token)
    end
  end

  describe "confirm_merge/1 and commit_eligible?/1" do
    test "an email match alone (no passwordless proof) is not commit-eligible" do
      %{attempt: attempt} = scenario()

      refute IdentityLinking.commit_eligible?(attempt)
      assert {:error, :not_ready} = IdentityLinking.confirm_merge(attempt)
    end

    test "a proven but unconfirmed attempt is not commit-eligible" do
      %{attempt: attempt} = scenario()

      {:ok, %{challenge_id: cid, raw_token: token}} =
        IdentityLinking.request_passwordless_proof(attempt)

      {:ok, proven} = IdentityLinking.submit_passwordless_proof(cid, token)

      refute IdentityLinking.commit_eligible?(proven)
    end

    test "a freshly proven and explicitly confirmed attempt with clear preflight is commit-eligible" do
      %{attempt: attempt} = scenario()

      {:ok, %{challenge_id: cid, raw_token: token}} =
        IdentityLinking.request_passwordless_proof(attempt)

      {:ok, proven} = IdentityLinking.submit_passwordless_proof(cid, token)

      assert {:ok, confirmed} = IdentityLinking.confirm_merge(proven)
      assert confirmed.confirmed_at
      assert IdentityLinking.commit_eligible?(confirmed)
    end

    test "confirmation is refused and the attempt marked conflicted on a preflight collision" do
      %{attempt: attempt, surviving_ws: sw, absorbed_ws: aw} = scenario()
      project_fixture(sw, name: "Roadmap")
      project_fixture(aw, name: "roadmap")

      {:ok, %{challenge_id: cid, raw_token: token}} =
        IdentityLinking.request_passwordless_proof(attempt)

      {:ok, proven} = IdentityLinking.submit_passwordless_proof(cid, token)

      assert {:error, :conflict} = IdentityLinking.confirm_merge(proven)
      assert reload(attempt).status == "conflict"
      refute IdentityLinking.commit_eligible?(reload(attempt))
    end

    test "an expired attempt is not commit-eligible even when proven and confirmed" do
      %{attempt: attempt} = scenario()

      {:ok, %{challenge_id: cid, raw_token: token}} =
        IdentityLinking.request_passwordless_proof(attempt)

      {:ok, proven} = IdentityLinking.submit_passwordless_proof(cid, token)
      {:ok, confirmed} = IdentityLinking.confirm_merge(proven)

      past = DateTime.add(DateTime.utc_now(), -60, :second) |> DateTime.truncate(:second)
      expired = confirmed |> Ecto.Changeset.change(expires_at: past) |> Repo.update!()

      refute IdentityLinking.commit_eligible?(expired)
    end
  end
end
