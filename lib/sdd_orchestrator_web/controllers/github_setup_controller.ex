defmodule SddOrchestratorWeb.GitHubSetupController do
  @moduledoc """
  GitHub App installation handoff and return.

    * `GET /github/install` — starts the installation for an onboarding attempt,
      binds a one-time `state` to this browser via the session, and redirects to
      the public `Orchestra-workflow` installation page.
    * `GET /github/setup` — the installation return. It validates the one-time
      state and routes back to the attempt's repository-access check, which
      re-reads access with the user's token.

  Return parameters are never trusted on their own: no access is granted and no
  project is created here. Any `installation_id` GitHub sends is only a hint; the
  repository-access check re-reads the authenticated user's installations before
  accepting access. Both routes require an authenticated session and only ever
  act on an attempt owned by the current account's workspace.
  """
  use SddOrchestratorWeb, :controller

  alias SddOrchestrator.Accounts
  alias SddOrchestrator.GitHubIntegration
  alias SddOrchestrator.Projects

  @state_key :github_install_state
  @attempt_key :github_install_attempt

  def install(conn, %{"attempt_id" => attempt_id}) do
    case owned_attempt(conn, attempt_id) do
      nil ->
        redirect(conn, to: ~p"/projects")

      attempt ->
        state = GitHubIntegration.random_url_token(16)

        conn
        |> put_session(@state_key, state)
        |> put_session(@attempt_key, attempt.id)
        |> redirect(external: GitHubIntegration.installation_url(state))
    end
  end

  def install(conn, _params), do: redirect(conn, to: ~p"/projects")

  def setup(conn, params) do
    session_state = get_session(conn, @state_key)
    attempt_id = get_session(conn, @attempt_key)

    conn = conn |> delete_session(@state_key) |> delete_session(@attempt_key)

    case attempt_id && owned_attempt(conn, attempt_id) do
      %{id: id} ->
        # Whether or not the returned state matched, the repository-access check
        # re-reads access from GitHub, so it never trusts the return parameters.
        # The state check is defense-in-depth against a forged return.
        _matched = valid_state?(session_state, params["state"])
        redirect(conn, to: ~p"/onboarding/repository-access/#{id}")

      _ ->
        redirect(conn, to: ~p"/projects")
    end
  end

  defp owned_attempt(conn, attempt_id) do
    workspace = Accounts.get_or_create_personal_workspace(conn.assigns.current_account)
    Projects.get_onboarding_attempt(workspace, attempt_id)
  end

  defp valid_state?(expected, returned)
       when is_binary(expected) and is_binary(returned) and byte_size(expected) > 0,
       do: Plug.Crypto.secure_compare(expected, returned)

  defp valid_state?(_expected, _returned), do: false
end
