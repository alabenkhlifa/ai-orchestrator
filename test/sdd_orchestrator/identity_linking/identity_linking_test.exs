defmodule SddOrchestrator.IdentityLinkingTest do
  @moduledoc """
  Domain proofs for candidate detection and the transient merge attempt: zero,
  one, and multiple (ambiguous) matches, ineligible addresses, candidate secrecy,
  idempotent reuse, concurrent convergence, and account-neutral non-matches.
  """
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Accounts.Account
  alias SddOrchestrator.IdentityLinking
  alias SddOrchestrator.IdentityLinking.IdentityMergeAttempt

  import SddOrchestrator.AccountsFixtures
  import SddOrchestrator.HostedAccessFixtures

  describe "find_candidate/2" do
    test "returns the single passwordless identity matching a GitHub email" do
      %{hosted_identity: hi, account: acct} =
        hosted_identity_fixture(email: "octocat@example.com")

      assert {:ok, bundle} = IdentityLinking.find_candidate("octocat@example.com")
      assert bundle.hosted_identity.id == hi.id
      assert bundle.account.id == acct.id
      assert bundle.personal_workspace.account_id == acct.id
    end

    test "applies the approved Gmail dot, tag, and case rules" do
      hosted_identity_fixture(email: "first.last@gmail.com")
      assert {:ok, _bundle} = IdentityLinking.find_candidate("FirstLast+work@gmail.com")
    end

    test "returns :none when nothing matches" do
      hosted_identity_fixture(email: "someone@example.com")
      assert :none = IdentityLinking.find_candidate("nobody@example.com")
    end

    test "returns :none for an ineligible non-ASCII or IDNA address" do
      hosted_identity_fixture(email: "cafe@example.com")
      assert :none = IdentityLinking.find_candidate("café@example.com")
      assert :none = IdentityLinking.find_candidate("user@xn--caf-dma.com")
    end

    test "fails closed to :ambiguous when the normalized form maps to multiple identities" do
      hosted_identity_fixture(email: "first.last@gmail.com")
      hosted_identity_fixture(email: "firstlast@gmail.com")

      assert :ambiguous = IdentityLinking.find_candidate("f.irstlast@gmail.com")
    end

    test "excludes the initiating account from matching itself" do
      %{account: acct} = hosted_identity_fixture(email: "self@example.com")
      assert :none = IdentityLinking.find_candidate("self@example.com", acct.id)
    end
  end

  describe "start_merge_attempt/2" do
    setup do
      %{absorbed: account_fixture()}
    end

    test "creates a transient attempt bound to both accounts for a single candidate", %{
      absorbed: absorbed
    } do
      %{hosted_identity: hi, account: surviving} =
        hosted_identity_fixture(email: "owner@example.com")

      assert {:ok, %IdentityMergeAttempt{} = attempt} =
               IdentityLinking.start_merge_attempt(absorbed, "owner@example.com")

      assert attempt.absorbed_account_id == absorbed.id
      assert attempt.surviving_account_id == surviving.id
      assert attempt.candidate_hosted_identity_id == hi.id
      assert attempt.status == "detected"
      assert attempt.github_proven_at
      assert is_nil(attempt.passwordless_proven_at)
      assert is_nil(attempt.confirmed_at)
      assert is_nil(attempt.committed_at)
      assert DateTime.compare(attempt.expires_at, DateTime.utc_now()) == :gt
    end

    test "does not disclose the candidate account on the transient record", %{absorbed: absorbed} do
      hosted_identity_fixture(email: "secret-owner@example.com")

      {:ok, attempt} = IdentityLinking.start_merge_attempt(absorbed, "secret-owner@example.com")

      refute inspect(attempt) =~ "secret-owner@example.com"
      # The record holds only id references — never the candidate's email, name, or projects.
      refute Map.has_key?(Map.from_struct(attempt), :email)
      refute Map.has_key?(Map.from_struct(attempt), :delivery_email)
    end

    test "returns account-neutral :none and creates no attempt for no match", %{
      absorbed: absorbed
    } do
      assert {:ok, :none} = IdentityLinking.start_merge_attempt(absorbed, "nobody@example.com")
      assert Repo.aggregate(IdentityMergeAttempt, :count) == 0
    end

    test "returns account-neutral :none and creates no attempt for an ambiguous match", %{
      absorbed: absorbed
    } do
      hosted_identity_fixture(email: "first.last@gmail.com")
      hosted_identity_fixture(email: "firstlast@gmail.com")

      assert {:ok, :none} = IdentityLinking.start_merge_attempt(absorbed, "firstlast@gmail.com")
      assert Repo.aggregate(IdentityMergeAttempt, :count) == 0
    end

    test "reuses one live attempt across repeated detection (idempotent)", %{absorbed: absorbed} do
      hosted_identity_fixture(email: "owner@example.com")

      {:ok, a1} = IdentityLinking.start_merge_attempt(absorbed, "owner@example.com")
      {:ok, a2} = IdentityLinking.start_merge_attempt(absorbed, "owner@example.com")

      assert a1.id == a2.id
      assert Repo.aggregate(IdentityMergeAttempt, :count) == 1
    end

    test "concurrent detection converges to a single live attempt", %{absorbed: absorbed} do
      hosted_identity_fixture(email: "owner@example.com")

      results =
        1..5
        |> Enum.map(fn _ ->
          Task.async(fn -> IdentityLinking.start_merge_attempt(absorbed, "owner@example.com") end)
        end)
        |> Task.await_many()

      assert Enum.all?(results, &match?({:ok, %IdentityMergeAttempt{}}, &1))
      ids = results |> Enum.map(fn {:ok, a} -> a.id end) |> Enum.uniq()
      assert length(ids) == 1
      assert Repo.aggregate(IdentityMergeAttempt, :count) == 1
    end
  end

  describe "get_live_attempt/1 and abort_merge_attempt/1" do
    setup do
      absorbed = account_fixture()
      hosted_identity_fixture(email: "owner@example.com")
      {:ok, attempt} = IdentityLinking.start_merge_attempt(absorbed, "owner@example.com")
      %{absorbed: absorbed, attempt: attempt}
    end

    test "get_live_attempt returns a live attempt and nil for a bad id", %{attempt: attempt} do
      assert %IdentityMergeAttempt{id: id} = IdentityLinking.get_live_attempt(attempt.id)
      assert id == attempt.id
      assert is_nil(IdentityLinking.get_live_attempt("not-a-uuid"))
      assert is_nil(IdentityLinking.get_live_attempt(Ecto.UUID.generate()))
    end

    test "aborting is non-mutating for identities and frees the live slot", %{
      absorbed: absorbed,
      attempt: attempt
    } do
      accounts_before = Repo.aggregate(Account, :count)

      assert {:ok, aborted} = IdentityLinking.abort_merge_attempt(attempt)
      assert aborted.status == "aborted"
      assert is_nil(IdentityLinking.get_live_attempt(attempt.id))
      assert Repo.aggregate(Account, :count) == accounts_before

      # A fresh detection is no longer blocked by the aborted attempt.
      assert {:ok, %IdentityMergeAttempt{} = a2} =
               IdentityLinking.start_merge_attempt(absorbed, "owner@example.com")

      assert a2.id != attempt.id
    end
  end
end
