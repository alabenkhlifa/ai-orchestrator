defmodule SddOrchestratorWeb.HostedUserAuth do
  @moduledoc """
  Resolves the hosted-session credential for controller and LiveView requests.

  Hosted authorization is kept separate from GitHub application sessions and is
  never copied into coding-agent or worker capabilities.
  """
  use SddOrchestratorWeb, :verified_routes

  import Phoenix.Controller
  import Plug.Conn

  alias SddOrchestrator.HostedAccess.{SessionCookie, Sessions}

  @session_key SessionCookie.session_key()

  @doc "Stores the signed hosted credential in the protected browser session."
  def put_session_cookie(conn, %SessionCookie{} = session_cookie) do
    conn
    |> configure_session(renew: true)
    |> put_session(@session_key, session_cookie.value)
  end

  @doc "Resolves and assigns the current hosted identity, workspace, and session."
  def fetch_current_hosted_access(conn, _opts) do
    signed_cookie = get_session(conn, @session_key)

    case Sessions.authenticate(signed_cookie) do
      {:ok, access} ->
        conn
        |> configure_session(renew: true)
        |> put_session(@session_key, access.session_cookie.value)
        |> assign_hosted_access(access)

      :error ->
        if is_nil(signed_cookie) do
          assign_hosted_access(conn, nil)
        else
          conn
          |> delete_session(@session_key)
          |> assign_hosted_access(nil)
        end
    end
  end

  @doc "Requires a valid hosted session before the scoped controller action runs."
  def require_hosted_authenticated(conn, _opts) do
    if conn.assigns[:current_hosted_identity] do
      conn
    else
      conn
      |> redirect(to: ~p"/?#{[hosted_access: "required"]}")
      |> halt()
    end
  end

  @doc "Revokes only this browser's hosted session and removes its credential."
  def sign_out_current(conn) do
    conn |> get_session(@session_key) |> Sessions.revoke_current()

    conn
    |> delete_session(@session_key)
    |> configure_session(renew: true)
  end

  @doc "Removes the hosted credential after an all-device revocation."
  def clear_session_cookie(conn) do
    conn
    |> delete_session(@session_key)
    |> configure_session(renew: true)
  end

  @doc """
  LiveView hooks that either assign hosted access when present or require a
  valid hosted session before the LiveView mounts.
  """
  def on_mount(kind, params, session, socket)

  def on_mount(:mount_current_hosted_access, _params, session, socket) do
    {:cont, mount_hosted_access(socket, session)}
  end

  def on_mount(:require_hosted_authenticated, _params, session, socket) do
    socket = mount_hosted_access(socket, session)

    if socket.assigns.current_hosted_identity do
      {:cont, socket}
    else
      {:halt,
       Phoenix.LiveView.redirect(socket,
         to: ~p"/?#{[hosted_access: "required"]}"
       )}
    end
  end

  defp mount_hosted_access(socket, session) do
    access =
      case Sessions.authenticate(session[Atom.to_string(@session_key)]) do
        {:ok, access} -> access
        :error -> nil
      end

    socket
    |> Phoenix.Component.assign(:current_hosted_access, access)
    |> Phoenix.Component.assign(
      :current_hosted_identity,
      access && access.hosted_identity
    )
    |> Phoenix.Component.assign(
      :current_hosted_session,
      access && access.session
    )
    |> Phoenix.Component.assign(
      :current_hosted_workspace,
      access && access.personal_workspace
    )
  end

  defp assign_hosted_access(conn, nil) do
    conn
    |> assign(:current_hosted_access, nil)
    |> assign(:current_hosted_identity, nil)
    |> assign(:current_hosted_session, nil)
    |> assign(:current_hosted_workspace, nil)
  end

  defp assign_hosted_access(conn, access) do
    conn
    |> assign(:current_hosted_access, access)
    |> assign(:current_hosted_identity, access.hosted_identity)
    |> assign(:current_hosted_session, access.session)
    |> assign(:current_hosted_workspace, access.personal_workspace)
  end
end
