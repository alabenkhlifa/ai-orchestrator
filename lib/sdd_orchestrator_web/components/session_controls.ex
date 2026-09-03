defmodule SddOrchestratorWeb.SessionControls do
  @moduledoc """
  The sign-out target a screen offers, as one owned value (specs/45 Task 7).

  Only the GitHub sign-in issues the application session, so an account with no
  GitHub identity is browsing on its hosted session and that is the session to
  end. Sending such a person to `/auth/sign_out` revokes nothing: it finds no
  application session token, and the browser only looks signed out because the
  whole cookie is cleared, while the hosted session record stays active.

  The project catalog and the project dashboard both offer this control. The
  answer lives here so the two screens read one value instead of holding two
  copies that drift.
  """
  use SddOrchestratorWeb, :verified_routes

  @doc "The route that ends the session an account with this GitHub identity holds."
  def sign_out_path(nil), do: ~p"/hosted/session"
  def sign_out_path(_identity), do: ~p"/auth/sign_out"
end
