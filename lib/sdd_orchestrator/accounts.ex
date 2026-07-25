defmodule SddOrchestrator.Accounts do
  @moduledoc """
  Accounts context: GitHub authorization attempts, account/identity/credential
  provisioning, and the protected application-session lifecycle.

  Security properties enforced here:

    * Authorization `state` and session tokens are stored only as SHA-256
      digests; a database read cannot reconstruct a usable value.
    * The PKCE verifier and GitHub tokens are encrypted at rest.
    * Each authorization return is single-use: consumption is a conditional
      update, so a replayed callback finds nothing to consume.
    * A session is rejected before protected data loads once it is revoked, idle
      past 24 hours, or older than 30 days absolute.
  """
  import Ecto.Query

  alias SddOrchestrator.Accounts.{
    Account,
    ApplicationSession,
    GitHubAuthorizationAttempt,
    GitHubCredential,
    GitHubIdentity,
    PersonalWorkspace
  }

  alias SddOrchestrator.GitHubIntegration
  alias SddOrchestrator.Repo

  # 10 minutes: an authorization attempt is unusable after this window.
  @attempt_ttl_seconds 600
  # 24 hours idle / 30 days absolute session lifetime.
  @session_idle_seconds 24 * 60 * 60
  @session_absolute_seconds 30 * 24 * 60 * 60
  # Refresh a provider token this many seconds before its reported expiry.
  @refresh_leeway_seconds 120

  ## GitHub authorization attempts

  @doc """
  Starts a GitHub authorization attempt.

  Persists digests of a fresh `state` and browser nonce plus an encrypted PKCE
  verifier, and returns the authorize URL together with the raw `state` and
  `nonce` the caller must place in the browser flow cookie.
  """
  @spec start_github_authorization(String.t() | nil) ::
          {:ok, %{authorize_url: String.t(), browser_nonce: String.t()}} | {:error, term()}
  def start_github_authorization(return_to \\ nil) do
    state = GitHubIntegration.random_url_token(32)
    browser_nonce = GitHubIntegration.random_url_token(32)
    {verifier, challenge} = GitHubIntegration.new_pkce()

    attrs = %{
      state_digest: digest(state),
      browser_nonce_digest: digest(browser_nonce),
      pkce_verifier: verifier,
      return_to: sanitize_return_to(return_to),
      expires_at: seconds_from_now(@attempt_ttl_seconds)
    }

    with {:ok, _attempt} <-
           %GitHubAuthorizationAttempt{}
           |> GitHubAuthorizationAttempt.changeset(attrs)
           |> Repo.insert() do
      {:ok,
       %{
         authorize_url: GitHubIntegration.authorize_url(state, challenge),
         browser_nonce: browser_nonce
       }}
    end
  end

  @doc """
  Completes a GitHub authorization return.

  Validates the `state` against a live, unconsumed attempt bound to the same
  browser flow, consumes it exactly once, exchanges the code for tokens, resolves
  the stable GitHub identity, provisions or restores the account and encrypted
  credential, and issues a fresh session. Returns the raw session token to place
  in the cookie.
  """
  @spec complete_github_callback(String.t(), String.t(), String.t() | nil) ::
          {:ok, %{account: Account.t(), session_token: String.t(), return_to: String.t() | nil}}
          | {:error,
             :invalid_state | :expired | :nonce_mismatch | :already_consumed | :provider_failure}
  def complete_github_callback(state, code, browser_nonce)
      when is_binary(state) and is_binary(code) do
    with {:ok, attempt} <- consume_attempt(state, browser_nonce),
         {:ok, token} <- exchange(code, attempt.pkce_verifier),
         {:ok, user} <- fetch_user(token.access_token),
         {:ok, account} <- upsert_account(user, token) do
      {:ok, session_token} = create_session(account)
      {:ok, %{account: account, session_token: session_token, return_to: attempt.return_to}}
    end
  end

  def complete_github_callback(_state, _code, _nonce), do: {:error, :invalid_state}

  defp consume_attempt(state, browser_nonce) do
    now = now()

    case Repo.get_by(GitHubAuthorizationAttempt, state_digest: digest(state)) do
      nil ->
        {:error, :invalid_state}

      attempt ->
        cond do
          not is_nil(attempt.consumed_at) ->
            {:error, :already_consumed}

          DateTime.compare(attempt.expires_at, now) == :lt ->
            {:error, :expired}

          not valid_nonce?(attempt, browser_nonce) ->
            # Reject without consuming so the legitimate browser can still return.
            {:error, :nonce_mismatch}

          true ->
            claim_attempt(attempt, now)
        end
    end
  end

  # Single-use consumption: the conditional update makes a concurrent replay find
  # nothing left to claim.
  defp claim_attempt(attempt, now) do
    {count, _} =
      Repo.update_all(
        from(a in GitHubAuthorizationAttempt,
          where: a.id == ^attempt.id and is_nil(a.consumed_at)
        ),
        set: [consumed_at: now, updated_at: now]
      )

    if count == 1, do: {:ok, attempt}, else: {:error, :already_consumed}
  end

  defp valid_nonce?(_attempt, nonce) when not is_binary(nonce), do: false

  defp valid_nonce?(attempt, nonce),
    do: secure_equal?(attempt.browser_nonce_digest, digest(nonce))

  defp exchange(code, verifier) do
    case GitHubIntegration.exchange_code(code, verifier) do
      {:ok, token} -> {:ok, token}
      {:error, _reason} -> {:error, :provider_failure}
    end
  end

  defp fetch_user(access_token) do
    case GitHubIntegration.get_user(access_token) do
      {:ok, user} -> {:ok, user}
      {:error, _reason} -> {:error, :provider_failure}
    end
  end

  ## Accounts and identities

  @doc "Returns the GitHub identity for an account, or nil."
  def get_github_identity(account_id) do
    Repo.get_by(GitHubIdentity, account_id: account_id)
  end

  @doc "Returns the account for a GitHub numeric user id, or nil."
  def get_account_by_github_user_id(github_user_id) do
    GitHubIdentity
    |> Repo.get_by(github_user_id: github_user_id)
    |> case do
      nil -> nil
      identity -> Repo.get(Account, identity.account_id)
    end
  end

  ## Personal workspaces

  @doc "Returns the personal workspace for an account, or nil."
  @spec get_personal_workspace(binary()) :: PersonalWorkspace.t() | nil
  def get_personal_workspace(account_id) when is_binary(account_id) do
    Repo.get_by(PersonalWorkspace, account_id: account_id)
  end

  @doc """
  Restores the account's one stable personal workspace, creating it on first
  use. The unique `account_id` constraint plus `on_conflict: :nothing` makes this
  idempotent under retry and safe under concurrency: at most one workspace can
  ever exist for an account, and every caller resolves the same row.
  """
  @spec get_or_create_personal_workspace(Account.t() | binary()) :: PersonalWorkspace.t()
  def get_or_create_personal_workspace(%Account{id: account_id}),
    do: get_or_create_personal_workspace(account_id)

  def get_or_create_personal_workspace(account_id) when is_binary(account_id) do
    {:ok, _} =
      %PersonalWorkspace{}
      |> PersonalWorkspace.changeset(%{account_id: account_id})
      |> Repo.insert(on_conflict: :nothing, conflict_target: :account_id)

    Repo.get_by!(PersonalWorkspace, account_id: account_id)
  end

  defp upsert_account(user, token) do
    case Repo.get_by(GitHubIdentity, github_user_id: user.id) do
      %GitHubIdentity{} = identity ->
        account = Repo.get!(Account, identity.account_id)

        with {:ok, _identity} <- update_identity(identity, user),
             {:ok, _credential} <- upsert_credential(account.id, token) do
          {:ok, account}
        end

      nil ->
        create_account(user, token)
    end
  end

  defp create_account(user, token) do
    Ecto.Multi.new()
    |> Ecto.Multi.insert(:account, fn _changes ->
      Account.changeset(%Account{}, %{state: :active})
    end)
    |> Ecto.Multi.insert(:identity, fn %{account: account} ->
      GitHubIdentity.changeset(%GitHubIdentity{}, %{
        github_user_id: user.id,
        login: user.login,
        avatar_url: Map.get(user, :avatar_url),
        account_id: account.id
      })
    end)
    |> Ecto.Multi.insert(:credential, fn %{account: account} ->
      GitHubCredential.changeset(%GitHubCredential{}, credential_attrs(account.id, token))
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{account: account}} -> {:ok, account}
      {:error, _step, changeset, _} -> {:error, changeset}
    end
  end

  defp update_identity(identity, user) do
    identity
    |> GitHubIdentity.changeset(%{login: user.login, avatar_url: Map.get(user, :avatar_url)})
    |> Repo.update()
  end

  defp upsert_credential(account_id, token) do
    case Repo.get_by(GitHubCredential, account_id: account_id) do
      nil -> %GitHubCredential{}
      credential -> credential
    end
    |> GitHubCredential.changeset(credential_attrs(account_id, token))
    |> Repo.insert_or_update()
  end

  defp credential_attrs(account_id, token) do
    %{
      account_id: account_id,
      access_token: token.access_token,
      refresh_token: Map.get(token, :refresh_token),
      token_expires_at: expires_at_from(Map.get(token, :expires_in)),
      scopes: Map.get(token, :scope),
      revoked_at: nil
    }
  end

  @doc "Returns the (decrypted) credential for an account, or nil."
  def get_github_credential(account_id) do
    Repo.get_by(GitHubCredential, account_id: account_id)
  end

  @doc """
  Returns a currently valid GitHub access token for an account, refreshing it
  under a row lock when it is at or near its provider expiry. Never exposes the
  token outside the server boundary.
  """
  @spec valid_access_token(binary()) :: {:ok, String.t()} | {:error, term()}
  def valid_access_token(account_id) do
    Repo.transaction(fn ->
      credential =
        Repo.one(
          from c in GitHubCredential, where: c.account_id == ^account_id, lock: "FOR UPDATE"
        )

      cond do
        is_nil(credential) or not is_nil(credential.revoked_at) ->
          Repo.rollback(:no_credential)

        needs_refresh?(credential) ->
          refresh_locked(credential)

        true ->
          credential.access_token
      end
    end)
  end

  defp needs_refresh?(%GitHubCredential{token_expires_at: nil}), do: false

  defp needs_refresh?(%GitHubCredential{token_expires_at: expiry}) do
    DateTime.compare(expiry, seconds_from_now(@refresh_leeway_seconds)) != :gt
  end

  defp refresh_locked(%GitHubCredential{refresh_token: nil}), do: Repo.rollback(:no_refresh_token)

  defp refresh_locked(credential) do
    case GitHubIntegration.refresh_token(credential.refresh_token) do
      {:ok, token} ->
        {:ok, updated} = upsert_credential(credential.account_id, token)
        updated.access_token

      {:error, reason} ->
        # A failed refresh revokes the credential; connection state is handled
        # by the connection-status task, not here.
        credential |> GitHubCredential.changeset(%{revoked_at: now()}) |> Repo.update()
        Repo.rollback({:refresh_failed, reason})
    end
  end

  ## Application sessions

  @doc "Creates a fresh session for an account and returns the raw opaque token."
  @spec create_session(Account.t()) :: {:ok, String.t()}
  def create_session(%Account{} = account) do
    token = GitHubIntegration.random_url_token(32)
    now = now()

    {:ok, _session} =
      %ApplicationSession{}
      |> ApplicationSession.changeset(%{
        account_id: account.id,
        token_digest: digest(token),
        last_used_at: now,
        idle_expires_at: DateTime.add(now, @session_idle_seconds, :second),
        absolute_expires_at: DateTime.add(now, @session_absolute_seconds, :second)
      })
      |> Repo.insert()

    {:ok, token}
  end

  @doc """
  Resolves the account for a session token, sliding the idle expiry forward on
  success. Returns `:error` for a missing, revoked, idle-expired, or
  absolute-expired session — the caller must fail closed.
  """
  @spec fetch_account_by_session_token(String.t() | nil) :: {:ok, Account.t()} | :error
  def fetch_account_by_session_token(token) when is_binary(token) do
    now = now()

    session =
      Repo.one(
        from s in ApplicationSession,
          where: s.token_digest == ^digest(token)
      )

    cond do
      is_nil(session) ->
        :error

      session_invalid?(session, now) ->
        :error

      true ->
        {:ok, _} =
          session
          |> ApplicationSession.changeset(%{
            last_used_at: now,
            idle_expires_at: DateTime.add(now, @session_idle_seconds, :second)
          })
          |> Repo.update()

        {:ok, Repo.get!(Account, session.account_id)}
    end
  end

  def fetch_account_by_session_token(_), do: :error

  defp session_invalid?(session, now) do
    not is_nil(session.revoked_at) or
      DateTime.compare(session.idle_expires_at, now) == :lt or
      DateTime.compare(session.absolute_expires_at, now) == :lt
  end

  @doc "Revokes a session by its raw token (idempotent). Used on sign-out."
  @spec revoke_session(String.t() | nil) :: :ok
  def revoke_session(token) when is_binary(token) do
    now = now()

    Repo.update_all(
      from(s in ApplicationSession,
        where: s.token_digest == ^digest(token) and is_nil(s.revoked_at)
      ),
      set: [revoked_at: now, updated_at: now]
    )

    :ok
  end

  def revoke_session(_), do: :ok

  ## Helpers

  @doc "SHA-256 digest (lowercase hex) used for state, nonce, and session tokens."
  @spec digest(String.t()) :: String.t()
  def digest(value) when is_binary(value) do
    :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  end

  defp secure_equal?(a, b) when is_binary(a) and is_binary(b),
    do: :crypto.hash_equals(a, b)

  defp secure_equal?(_, _), do: false

  defp expires_at_from(nil), do: nil
  defp expires_at_from(seconds) when is_integer(seconds), do: seconds_from_now(seconds)

  defp seconds_from_now(seconds), do: DateTime.add(now(), seconds, :second)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  # Only allow app-local return paths to avoid open-redirects.
  defp sanitize_return_to("/" <> _ = path), do: path
  defp sanitize_return_to(_), do: nil
end
