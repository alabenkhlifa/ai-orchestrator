defmodule SddOrchestratorWeb.HostedSessionController do
  @moduledoc "Protected hosted-session revocation actions used by the Task 6 UI."
  use SddOrchestratorWeb, :controller

  alias SddOrchestrator.HostedAccess.Sessions
  alias SddOrchestratorWeb.HostedUserAuth

  def delete_current(conn, _params) do
    conn
    |> HostedUserAuth.sign_out_current()
    |> redirect(to: ~p"/?#{[hosted_access: "signed_out"]}")
  end

  def delete(conn, %{"id" => session_id}) do
    current_session = conn.assigns.current_hosted_session
    hosted_identity = conn.assigns.current_hosted_identity

    :ok = Sessions.revoke(hosted_identity, session_id)

    if session_id == current_session.id do
      conn
      |> HostedUserAuth.clear_session_cookie()
      |> redirect(to: ~p"/?#{[hosted_access: "signed_out"]}")
    else
      redirect(conn, to: ~p"/?#{[hosted_access: "session_revoked"]}")
    end
  end

  def delete_all(conn, _params) do
    :ok = Sessions.revoke_all(conn.assigns.current_hosted_identity)

    conn
    |> HostedUserAuth.clear_session_cookie()
    |> redirect(to: ~p"/?#{[hosted_access: "signed_out_all"]}")
  end
end
