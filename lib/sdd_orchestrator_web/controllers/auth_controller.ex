defmodule SddOrchestratorWeb.AuthController do
  @moduledoc """
  GitHub authorization endpoints.

    * `GET /auth/github` — starts an authorization attempt, binds the browser
      flow via the session, and redirects to GitHub with random `state` + PKCE.
    * `GET /auth/github/callback` — validates the return, exchanges the code, and
      establishes a rotated protected session.
    * `DELETE /auth/sign_out` — revokes the session and returns to the entry.

  Untrusted callback parameters are never trusted on their own: the `state` must
  match a live, unconsumed attempt bound to this browser, and access is only
  granted after the code is exchanged and the user resolved.
  """
  use SddOrchestratorWeb, :controller

  alias SddOrchestrator.Accounts
  alias SddOrchestrator.GitHubIntegration
  alias SddOrchestrator.IdentityLinking
  alias SddOrchestrator.IdentityLinking.IdentityMergeAttempt
  alias SddOrchestratorWeb.UserAuth

  @oauth_nonce_key :github_oauth_nonce

  def request(conn, params) do
    case Accounts.start_github_authorization(params["return_to"]) do
      {:ok, %{authorize_url: url, browser_nonce: nonce}} ->
        conn
        |> put_session(@oauth_nonce_key, nonce)
        |> redirect(external: url)

      {:error, _reason} ->
        redirect(conn, to: ~p"/?#{[auth: "failed"]}")
    end
  end

  # The user cancelled or denied authorization on GitHub.
  def callback(conn, %{"error" => _error}) do
    conn
    |> delete_session(@oauth_nonce_key)
    |> redirect(to: ~p"/?#{[auth: "cancelled"]}")
  end

  def callback(conn, %{"state" => state, "code" => code}) do
    nonce = get_session(conn, @oauth_nonce_key)

    case Accounts.complete_github_callback(state, code, nonce) do
      {:ok, %{account: account, session_token: token, return_to: return_to}} ->
        conn = UserAuth.put_session_token(conn, token)

        case detect_link_candidate(account) do
          {:ok, %IdentityMergeAttempt{} = attempt} ->
            redirect(conn, to: ~p"/identity/link/#{attempt.id}")

          :none ->
            redirect(conn, to: return_to || ~p"/projects")
        end

      {:error, _reason} ->
        conn
        |> delete_session(@oauth_nonce_key)
        |> redirect(to: ~p"/?#{[auth: "failed"]}")
    end
  end

  def callback(conn, _params) do
    conn
    |> delete_session(@oauth_nonce_key)
    |> redirect(to: ~p"/?#{[auth: "failed"]}")
  end

  def sign_out(conn, _params) do
    conn
    |> UserAuth.sign_out()
    |> put_flash(:info, "You have been signed out.")
    |> redirect(to: ~p"/")
  end

  # After a fresh GitHub sign-in, offer identity linking only when the verified
  # primary email uniquely matches an existing passwordless account. Any provider
  # failure, missing/ineligible email, or non-unique match resolves to `:none` so
  # sign-in proceeds normally and account-neutrally.
  defp detect_link_candidate(account) do
    with {:ok, token} <- Accounts.valid_access_token(account.id),
         {:ok, email} when is_binary(email) <- GitHubIntegration.verified_primary_email(token),
         {:ok, %IdentityMergeAttempt{} = attempt} <-
           IdentityLinking.start_merge_attempt(account, email) do
      {:ok, attempt}
    else
      _ -> :none
    end
  end
end
