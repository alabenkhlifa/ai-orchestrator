defmodule SddOrchestratorWeb.ProjectsLiveTest do
  @moduledoc """
  Proof for the protected landing: it renders for an authenticated account,
  exposes the sign-out control, and never leaks credentials into the payload.
  """
  use SddOrchestratorWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias SddOrchestrator.Accounts

  setup %{conn: conn} do
    register_and_log_in_account(%{conn: conn})
  end

  test "renders for an authenticated account with a sign-out control", %{
    conn: conn,
    account: account
  } do
    {:ok, _view, html} = live(conn, ~p"/projects")

    assert html =~ "Projects"
    assert html =~ "Sign out"
    assert html =~ ~s(href="/auth/sign_out")
    assert html =~ Accounts.get_github_identity(account.id).login
  end

  test "does not expose the GitHub access token in the payload", %{conn: conn, account: account} do
    {:ok, _view, html} = live(conn, ~p"/projects")
    credential = Accounts.get_github_credential(account.id)

    refute html =~ credential.access_token
  end
end
