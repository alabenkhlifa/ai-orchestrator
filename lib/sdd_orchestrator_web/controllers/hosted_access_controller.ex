defmodule SddOrchestratorWeb.HostedAccessController do
  @moduledoc "Account-neutral return endpoint for a delivered hosted magic link."
  use SddOrchestratorWeb, :controller

  alias SddOrchestrator.HostedAccess
  alias SddOrchestrator.HostedAccess.DeviceRecognition

  def verify(conn, %{"attempt" => attempt_id, "token" => raw_token}) do
    device_context =
      conn
      |> get_req_header("user-agent")
      |> List.first()
      |> DeviceRecognition.from_user_agent()

    case HostedAccess.verify_magic_link(attempt_id, raw_token, device_context) do
      {:ok, %{session_cookie: session_cookie}} ->
        conn
        |> protect_credential_response()
        |> SddOrchestratorWeb.HostedUserAuth.put_session_cookie(session_cookie)
        |> redirect(to: ~p"/?#{[hosted_access: "verified"]}")

      {:error, :invalid_or_expired} ->
        safe_failure(conn)
    end
  end

  def verify(conn, _params), do: safe_failure(conn)

  defp safe_failure(conn) do
    conn
    |> protect_credential_response()
    |> redirect(to: ~p"/?#{[hosted_access: "invalid"]}")
  end

  defp protect_credential_response(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("referrer-policy", "no-referrer")
  end
end
