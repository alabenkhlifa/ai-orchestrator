defmodule SddOrchestrator.AccountsTest do
  @moduledoc """
  Domain, persistence, session, and security proofs for the Accounts context:
  the GitHub authorization attempt lifecycle, account provisioning/restoration,
  encrypted credentials with refresh, and the protected session lifecycle.
  """
  use SddOrchestrator.DataCase, async: true

  alias SddOrchestrator.Accounts

  alias SddOrchestrator.Accounts.{
    ApplicationSession,
    GitHubAuthorizationAttempt,
    GitHubCredential,
    PersonalWorkspace,
    Workspace
  }

  alias SddOrchestrator.AccountsFixtures

  # Drives one full authorization round trip and returns the raw state used.
  defp start_and_extract_state do
    {:ok, %{authorize_url: url, browser_nonce: nonce}} =
      Accounts.start_github_authorization("/projects")

    state = URI.decode_query(URI.parse(url).query)["state"]
    {state, nonce}
  end

  describe "start_github_authorization/1" do
    test "persists digests and an encrypted PKCE verifier, never the raw state" do
      {:ok, %{authorize_url: url}} = Accounts.start_github_authorization(nil)
      query = URI.decode_query(URI.parse(url).query)

      assert query["code_challenge_method"] == "S256"
      assert byte_size(query["state"]) > 20

      attempt = Repo.one!(GitHubAuthorizationAttempt)
      # Only the digest of the state is stored, not the state itself.
      assert attempt.state_digest == Accounts.digest(query["state"])
      refute attempt.state_digest == query["state"]

      # The PKCE verifier column is encrypted at rest (not readable plaintext).
      [raw] = Repo.query!("SELECT pkce_verifier FROM github_authorization_attempts").rows |> hd()
      assert is_binary(raw)
      refute raw == attempt.pkce_verifier
    end
  end

  describe "complete_github_callback/3" do
    test "provisions an account, identity, and encrypted credential, and issues a session" do
      {state, nonce} = start_and_extract_state()

      assert {:ok, %{account: account, session_token: token, return_to: "/projects"}} =
               Accounts.complete_github_callback(state, "user-42", nonce)

      identity = Accounts.get_github_identity(account.id)
      assert identity.github_user_id == 42
      assert identity.login == "user-42"

      credential = Accounts.get_github_credential(account.id)
      assert credential.access_token == "fake-access:user-42"

      # The session token resolves back to the same account.
      assert {:ok, resolved} = Accounts.fetch_account_by_session_token(token)
      assert resolved.id == account.id
    end

    test "restores the same account for a returning GitHub user (no duplicate)" do
      {s1, n1} = start_and_extract_state()
      {:ok, %{account: first}} = Accounts.complete_github_callback(s1, "user-7", n1)

      {s2, n2} = start_and_extract_state()
      {:ok, %{account: second}} = Accounts.complete_github_callback(s2, "user-7", n2)

      assert first.id == second.id
      assert Repo.aggregate(from(a in "accounts"), :count) == 1
    end

    test "consumes the attempt exactly once; a replay is rejected" do
      {state, nonce} = start_and_extract_state()
      assert {:ok, _} = Accounts.complete_github_callback(state, "user-1", nonce)

      assert {:error, :already_consumed} =
               Accounts.complete_github_callback(state, "user-1", nonce)
    end

    test "rejects an unknown state" do
      {:ok, %{browser_nonce: nonce}} = Accounts.start_github_authorization(nil)

      assert {:error, :invalid_state} =
               Accounts.complete_github_callback("not-a-real-state", "user-1", nonce)
    end

    test "rejects a mismatched browser nonce (return bound to the wrong browser)" do
      {state, _nonce} = start_and_extract_state()

      assert {:error, :nonce_mismatch} =
               Accounts.complete_github_callback(state, "user-1", "attacker-nonce")
    end

    test "rejects an expired attempt" do
      {state, nonce} = start_and_extract_state()

      Repo.update_all(GitHubAuthorizationAttempt,
        set: [
          expires_at: DateTime.add(DateTime.utc_now(), -60, :second) |> DateTime.truncate(:second)
        ]
      )

      assert {:error, :expired} = Accounts.complete_github_callback(state, "user-1", nonce)
    end

    test "surfaces provider failure without creating an account" do
      {state, nonce} = start_and_extract_state()

      assert {:error, :provider_failure} =
               Accounts.complete_github_callback(state, "provider-failure", nonce)

      assert Repo.aggregate(from(a in "accounts"), :count) == 0
    end
  end

  describe "credentials" do
    test "tokens are encrypted at rest and redacted from inspect" do
      account = AccountsFixtures.account_fixture(login: "octocat")
      credential = Accounts.get_github_credential(account.id)

      # Column ciphertext differs from the decrypted value.
      [raw] = Repo.query!("SELECT access_token FROM github_credentials").rows |> hd()
      refute raw == credential.access_token
      refute inspect(credential) =~ credential.access_token
    end

    test "valid_access_token/1 refreshes a token at or near expiry" do
      account =
        AccountsFixtures.account_fixture(login: "user-9", refresh_token: "fake-refresh:user-9")

      Repo.update_all(GitHubCredential,
        set: [
          token_expires_at:
            DateTime.add(DateTime.utc_now(), 10, :second) |> DateTime.truncate(:second)
        ]
      )

      assert {:ok, token} = Accounts.valid_access_token(account.id)
      assert token =~ "refreshed-"
    end
  end

  describe "personal workspaces" do
    test "creates one stable workspace and restores the same row" do
      account = AccountsFixtures.account_fixture()

      workspace = Accounts.get_or_create_personal_workspace(account)
      assert workspace.account_id == account.id

      # Restoration returns the same workspace, not a new one.
      assert Accounts.get_personal_workspace(account.id).id == workspace.id
      assert Accounts.get_or_create_personal_workspace(account).id == workspace.id
    end

    test "is idempotent under retry: no duplicate workspace" do
      account = AccountsFixtures.account_fixture()

      first = Accounts.get_or_create_personal_workspace(account)
      second = Accounts.get_or_create_personal_workspace(account)

      assert first.id == second.id

      assert Repo.aggregate(
               from(w in PersonalWorkspace, where: w.account_id == ^account.id),
               :count
             ) ==
               1
    end

    test "the unique account constraint makes a concurrent duplicate impossible" do
      account = AccountsFixtures.account_fixture()
      _first = Accounts.get_or_create_personal_workspace(account)

      # A second plain insert (the losing side of a concurrent create) is rejected
      # by the database rather than producing a second workspace.
      duplicate_root =
        %Workspace{}
        |> Workspace.changeset(%{kind: "hosted"})
        |> Repo.insert!()

      assert {:error, changeset} =
               %PersonalWorkspace{}
               |> PersonalWorkspace.changeset(%{
                 id: duplicate_root.id,
                 account_id: account.id
               })
               |> Repo.insert()

      assert %{account_id: ["has already been taken"]} = errors_on(changeset)
    end

    test "workspaces are isolated between accounts" do
      one = AccountsFixtures.account_fixture()
      two = AccountsFixtures.account_fixture()

      ws_one = Accounts.get_or_create_personal_workspace(one)
      ws_two = Accounts.get_or_create_personal_workspace(two)

      refute ws_one.id == ws_two.id
      assert ws_one.account_id == one.id
      assert ws_two.account_id == two.id
    end
  end

  describe "application sessions" do
    setup do
      %{account: AccountsFixtures.account_fixture()}
    end

    test "a fresh session resolves and slides its idle expiry", %{account: account} do
      {:ok, token} = Accounts.create_session(account)
      before = Repo.one!(from s in ApplicationSession, select: s.idle_expires_at)

      assert {:ok, resolved} = Accounts.fetch_account_by_session_token(token)
      assert resolved.id == account.id

      after_use = Repo.one!(from s in ApplicationSession, select: s.idle_expires_at)
      assert DateTime.compare(after_use, before) in [:gt, :eq]
    end

    test "an idle-expired session is rejected", %{account: account} do
      {:ok, token} = Accounts.create_session(account)

      Repo.update_all(ApplicationSession,
        set: [
          idle_expires_at:
            DateTime.add(DateTime.utc_now(), -1, :second) |> DateTime.truncate(:second)
        ]
      )

      assert :error = Accounts.fetch_account_by_session_token(token)
    end

    test "an absolute-expired session is rejected even if recently used", %{account: account} do
      {:ok, token} = Accounts.create_session(account)

      Repo.update_all(ApplicationSession,
        set: [
          absolute_expires_at:
            DateTime.add(DateTime.utc_now(), -1, :second) |> DateTime.truncate(:second)
        ]
      )

      assert :error = Accounts.fetch_account_by_session_token(token)
    end

    test "revocation rejects a previously valid session", %{account: account} do
      {:ok, token} = Accounts.create_session(account)
      assert {:ok, _} = Accounts.fetch_account_by_session_token(token)

      :ok = Accounts.revoke_session(token)
      assert :error = Accounts.fetch_account_by_session_token(token)
    end

    test "only the token digest is stored, never the raw token", %{account: account} do
      {:ok, token} = Accounts.create_session(account)
      digest = Repo.one!(from s in ApplicationSession, select: s.token_digest)
      assert digest == Accounts.digest(token)
      refute digest == token
    end
  end
end
