defmodule SddOrchestratorWeb.AuthControllerTest do
  @moduledoc """
  Integration proof for the GitHub authorization endpoints: the PKCE + state
  redirect, a full sign-in round trip, cancellation, failure, replay rejection,
  and sign-out.
  """
  use SddOrchestratorWeb.ConnCase, async: true

  alias SddOrchestrator.Accounts
  alias SddOrchestrator.AccountsFixtures

  defp state_from(conn) do
    conn
    |> redirected_to(302)
    |> URI.parse()
    |> Map.get(:query)
    |> URI.decode_query()
    |> Map.get("state")
  end

  describe "GET /auth/github" do
    test "redirects to GitHub with random state and PKCE S256", %{conn: conn} do
      conn = get(conn, ~p"/auth/github")
      url = redirected_to(conn, 302)

      assert url =~ "https://github.com/login/oauth/authorize"
      query = url |> URI.parse() |> Map.get(:query) |> URI.decode_query()
      assert query["code_challenge_method"] == "S256"
      assert byte_size(query["code_challenge"]) > 20
      # The browser flow is bound via a session nonce.
      assert get_session(conn, :github_oauth_nonce)
    end
  end

  describe "GET /auth/github/callback" do
    test "a valid return signs the user in and routes to the catalog", %{conn: conn} do
      conn = get(conn, ~p"/auth/github")
      state = state_from(conn)

      conn = get(conn, ~p"/auth/github/callback?#{[state: state, code: "user-11"]}")

      assert redirected_to(conn) == ~p"/projects"
      assert token = get_session(conn, :session_token)
      assert {:ok, account} = Accounts.fetch_account_by_session_token(token)
      assert Accounts.get_github_identity(account.id).github_user_id == 11
    end

    test "a cancelled authorization returns to the entry with a cancel state", %{conn: conn} do
      conn = get(conn, ~p"/auth/github/callback?#{[error: "access_denied"]}")
      assert redirected_to(conn) =~ "auth=cancelled"
    end

    test "an invalid state returns to the entry with a failure state", %{conn: conn} do
      conn = get(conn, ~p"/auth/github")
      _ = state_from(conn)
      conn = get(conn, ~p"/auth/github/callback?#{[state: "forged", code: "user-1"]}")
      assert redirected_to(conn) =~ "auth=failed"
    end

    test "a replayed callback is rejected", %{conn: conn} do
      conn = get(conn, ~p"/auth/github")
      state = state_from(conn)

      conn = get(conn, ~p"/auth/github/callback?#{[state: state, code: "user-3"]}")
      assert redirected_to(conn) == ~p"/projects"

      conn = get(conn, ~p"/auth/github/callback?#{[state: state, code: "user-3"]}")
      assert redirected_to(conn) =~ "auth=failed"
    end
  end

  describe "DELETE /auth/sign_out" do
    test "revokes the session and returns to the entry", %{conn: conn} do
      account = AccountsFixtures.account_fixture()
      {:ok, token} = Accounts.create_session(account)
      conn = conn |> init_test_session(%{}) |> put_session(:session_token, token)

      conn = delete(conn, ~p"/auth/sign_out")

      assert redirected_to(conn) == ~p"/"
      assert :error = Accounts.fetch_account_by_session_token(token)
    end
  end
end
