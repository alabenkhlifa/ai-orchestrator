defmodule SddOrchestratorWeb.EntryLiveTest do
  @moduledoc """
  LiveView proof for the entry surface and session-aware routing: the two-action
  chooser, the cancelled/failed recovery states, valid-session bypass, and
  protected-route fail-closed behavior.
  """
  use SddOrchestratorWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  describe "unauthenticated entry" do
    test "shows exactly the two primary actions", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "Login with GitHub"
      assert html =~ "Work without GitHub"
      assert html =~ ~s(href="/auth/github")
      assert html =~ ~s(href="/onboarding/local")
    end

    test "renders the failure recovery state with retry", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/?#{[auth: "failed"]}")

      assert html =~ "connect to GitHub"
      assert html =~ "Try again"
    end

    test "renders the cancelled recovery state", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/?#{[auth: "cancelled"]}")

      assert html =~ "Authentication cancelled"
      assert html =~ "Try again"
    end
  end

  describe "session-aware routing" do
    test "a valid session bypasses the entry and opens the catalog", %{conn: conn} do
      %{conn: conn} = register_and_log_in_account(%{conn: conn})
      assert {:error, {:redirect, %{to: "/projects"}}} = live(conn, ~p"/")
    end

    # The catalog now resolves the acting identity, so a request with neither
    # session halts to the entry surface carrying the hosted-access notice.
    test "a protected route fails closed to the entry without a session", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/?hosted_access=required"}}} = live(conn, ~p"/projects")
    end
  end
end
