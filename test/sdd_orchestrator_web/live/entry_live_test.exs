defmodule SddOrchestratorWeb.EntryLiveTest do
  @moduledoc """
  LiveView proof for the entry surface and session-aware routing: the two-action
  chooser, the cancelled/failed recovery states, valid-session bypass for either
  sign-in, and protected-route fail-closed behavior.
  """
  use SddOrchestratorWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias SddOrchestrator.Accounts.HostedSession
  alias SddOrchestrator.HostedAccess.SessionCookie
  alias SddOrchestrator.HostedAccess.Sessions
  alias SddOrchestrator.HostedAccessFixtures
  alias SddOrchestrator.Repo

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
    test "an application session bypasses the entry and opens the catalog", %{conn: conn} do
      %{conn: conn} = register_and_log_in_account(%{conn: conn})
      assert {:error, {:redirect, %{to: "/projects"}}} = live(conn, ~p"/")
    end

    test "a hosted session bypasses the entry and opens the catalog", %{conn: conn} do
      hosted = HostedAccessFixtures.verified_hosted_session_fixture(email: "entry@example.com")

      assert {:error, {:redirect, %{to: "/projects"}}} =
               conn |> hosted_session(hosted) |> live(~p"/")
    end

    test "both sessions together still open the catalog", %{conn: conn} do
      %{conn: conn} = register_and_log_in_account(%{conn: conn})

      hosted =
        HostedAccessFixtures.verified_hosted_session_fixture(email: "entry-both@example.com")

      assert {:error, {:redirect, %{to: "/projects"}}} =
               conn |> hosted_session(hosted) |> live(~p"/")
    end

    test "an expired hosted session still renders the chooser", %{conn: conn} do
      hosted =
        HostedAccessFixtures.verified_hosted_session_fixture(email: "entry-expired@example.com")

      Repo.update_all(
        from(session in HostedSession, where: session.id == ^hosted.session.id),
        set: [expires_at: DateTime.utc_now() |> DateTime.add(-1, :second)]
      )

      {:ok, _view, html} = conn |> hosted_session(hosted) |> live(~p"/")

      assert html =~ "Login with GitHub"
      assert html =~ "Work without GitHub"
    end

    test "a revoked hosted session still renders the chooser", %{conn: conn} do
      hosted =
        HostedAccessFixtures.verified_hosted_session_fixture(email: "entry-revoked@example.com")

      :ok = Sessions.revoke_current(hosted.session_cookie.value)

      {:ok, _view, html} = conn |> hosted_session(hosted) |> live(~p"/")

      assert html =~ "Login with GitHub"
      assert html =~ "Work without GitHub"
    end
  end

  describe "turn-away notices" do
    # The catalog takes either sign-in, so its notice must not send a GitHub
    # owner off to verify an email.
    test "a project screen without a session asks for a sign-in and names none", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/?project_access=required"}}} = live(conn, ~p"/projects")

      {:ok, view, html} = live(conn, ~p"/?#{[project_access: "required"]}")

      assert html =~ "Sign in to open your projects."

      notice = view |> element("[role=note]") |> render()
      refute notice =~ "GitHub"
      refute notice =~ "email"
      refute notice =~ "hosted"
    end

    test "a hosted-only screen keeps its own verify-your-email sentence", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/?hosted_access=required"}}} =
               live(conn, ~p"/hosted/access/sessions")

      {:ok, _view, html} = live(conn, ~p"/?#{[hosted_access: "required"]}")

      assert html =~ "Verify your email before opening hosted project data."
    end
  end

  defp hosted_session(conn, hosted) do
    Plug.Test.init_test_session(conn, %{
      SessionCookie.session_key() => hosted.session_cookie.value
    })
  end
end
