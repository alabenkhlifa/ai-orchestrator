defmodule SddOrchestratorWeb.UserAuth do
  @moduledoc """
  Session resolution for protected routes.

  The opaque session token lives in the signed, `HttpOnly`, `SameSite=Lax` Plug
  session cookie; the server keeps only its digest. This module resolves the
  current account from that token before protected content renders and fails
  closed for a missing, revoked, or expired session.
  """
  use SddOrchestratorWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias SddOrchestrator.Accounts

  @session_token_key :session_token

  @doc "Plug: assigns `:current_account` from the session token (or nil)."
  def fetch_current_account(conn, _opts) do
    account =
      case get_session(conn, @session_token_key) do
        nil -> nil
        token -> account_from_token(token)
      end

    assign(conn, :current_account, account)
  end

  @doc "Plug: requires an authenticated account, else redirects to the entry surface."
  def require_authenticated(conn, _opts) do
    if conn.assigns[:current_account] do
      conn
    else
      conn
      |> redirect(to: ~p"/")
      |> halt()
    end
  end

  @doc """
  Renews the session cookie and stores a freshly issued opaque session token,
  rotating away any prior token to prevent session fixation.
  """
  def put_session_token(conn, token) do
    conn
    |> renew_session()
    |> put_session(@session_token_key, token)
  end

  @doc "Revokes the current session server-side and clears the session cookie."
  def sign_out(conn) do
    conn |> get_session(@session_token_key) |> Accounts.revoke_session()
    renew_session(conn)
  end

  @doc "The Plug session key holding the opaque session token."
  def session_token_key, do: @session_token_key

  ## LiveView on_mount hooks

  @doc """
  `on_mount` hooks:

    * `:mount_current_account` — assigns `:current_account` (or nil).
    * `:require_authenticated` — halts to the entry surface without one.
    * `:redirect_if_authenticated` — sends an active session to the catalog.
  """
  def on_mount(:mount_current_account, _params, session, socket) do
    {:cont, mount_current_account(socket, session)}
  end

  def on_mount(:require_authenticated, _params, session, socket) do
    socket = mount_current_account(socket, session)

    if socket.assigns.current_account do
      {:cont, socket}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/")}
    end
  end

  def on_mount(:redirect_if_authenticated, _params, session, socket) do
    socket = mount_current_account(socket, session)

    if socket.assigns.current_account do
      {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/projects")}
    else
      {:cont, socket}
    end
  end

  @doc """
  Resolves the account behind a LiveView `session` map's session token, or nil.

  Exposed so a hook that resolves more than this one credential reads the
  session token through its owner rather than repeating the key and the
  fail-closed lookup.
  """
  @spec account_from_session(map()) :: Accounts.Account.t() | nil
  def account_from_session(session) do
    case session[Atom.to_string(@session_token_key)] do
      nil -> nil
      token -> account_from_token(token)
    end
  end

  defp mount_current_account(socket, session) do
    Phoenix.Component.assign_new(socket, :current_account, fn ->
      account_from_session(session)
    end)
  end

  defp account_from_token(token) do
    case Accounts.fetch_account_by_session_token(token) do
      {:ok, account} -> account
      :error -> nil
    end
  end

  defp renew_session(conn) do
    delete_csrf_token()

    conn
    |> configure_session(renew: true)
    |> clear_session()
  end
end
