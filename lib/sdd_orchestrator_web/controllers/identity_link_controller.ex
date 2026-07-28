defmodule SddOrchestratorWeb.IdentityLinkController do
  @moduledoc """
  Handles the passwordless proof link emailed during identity linking.

  `GET /identity/link/verify` verifies the single-use token for a challenge and,
  on success, returns the user to the linking confirmation. Every invalid,
  expired, mismatched, or replayed link gets the same account-neutral response and
  changes nothing.
  """
  use SddOrchestratorWeb, :controller

  alias SddOrchestrator.IdentityLinking

  def verify(conn, %{"challenge" => challenge, "token" => token})
      when is_binary(challenge) and is_binary(token) do
    case IdentityLinking.submit_passwordless_proof(challenge, token) do
      {:ok, attempt} ->
        redirect(conn, to: ~p"/identity/link/#{attempt.id}")

      {:error, :invalid_or_expired} ->
        conn
        |> put_flash(:error, "That verification link is invalid or expired. Nothing was changed.")
        |> redirect(to: ~p"/projects")
    end
  end

  def verify(conn, _params) do
    conn
    |> put_flash(:error, "That verification link is invalid or expired. Nothing was changed.")
    |> redirect(to: ~p"/projects")
  end
end
