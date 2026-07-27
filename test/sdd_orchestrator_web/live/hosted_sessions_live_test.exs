defmodule SddOrchestratorWeb.HostedSessionsLiveTest do
  use SddOrchestratorWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias SddOrchestrator.Accounts.HostedSession
  alias SddOrchestrator.HostedAccess.{SessionCookie, Sessions}
  alias SddOrchestrator.HostedAccessFixtures
  alias SddOrchestrator.Repo

  test "requires hosted authorization before rendering device data", %{conn: conn} do
    assert {:error, {:redirect, %{to: location}}} =
             live(conn, ~p"/hosted/access/sessions")

    assert location == ~p"/?#{[hosted_access: "required"]}"
  end

  test "lists coarse active-device details and marks the current device", %{conn: conn} do
    current =
      HostedAccessFixtures.verified_hosted_session_fixture(
        email: "sessions-ui@example.com",
        user_agent_family: "Firefox",
        os_family: "Linux"
      )

    assert {:ok, other_session, other_cookie} =
             Sessions.create(current.hosted_identity, %{
               user_agent_family: "Safari",
               os_family: "iOS"
             })

    conn =
      init_test_session(conn, %{
        SessionCookie.session_key() => current.session_cookie.value
      })

    {:ok, _view, html} = live(conn, ~p"/hosted/access/sessions")

    assert html =~ "Firefox on Linux"
    assert html =~ "Safari on iOS"
    assert html =~ "Current device"
    assert html =~ "no IP address or fingerprint is stored"
    assert html =~ "support request"
    refute html =~ current.session_cookie.value
    refute html =~ other_cookie.value
    assert Repo.get(HostedSession, other_session.id)
  end

  test "revokes one other device with accessible feedback and keeps the current session", %{
    conn: conn
  } do
    current =
      HostedAccessFixtures.verified_hosted_session_fixture(email: "revoke-ui@example.com")

    assert {:ok, other_session, other_cookie} =
             Sessions.create(current.hosted_identity, %{
               user_agent_family: "Safari",
               os_family: "macOS"
             })

    conn =
      init_test_session(conn, %{
        SessionCookie.session_key() => current.session_cookie.value
      })

    {:ok, view, _html} = live(conn, ~p"/hosted/access/sessions")

    html =
      view
      |> element(
        ~s(button[phx-value-id="#{other_session.id}"]),
        "Sign out"
      )
      |> render_click()

    assert html =~ "That device session has been signed out"
    refute html =~ "Safari on macOS"
    assert {:ok, _current} = Sessions.authenticate(current.session_cookie.value)
    assert :error = Sessions.authenticate(other_cookie.value)
  end

  test "renders explicit current and all-device sign-out actions", %{conn: conn} do
    current =
      HostedAccessFixtures.verified_hosted_session_fixture(email: "actions-ui@example.com")

    conn =
      init_test_session(conn, %{
        SessionCookie.session_key() => current.session_cookie.value
      })

    {:ok, view, _html} = live(conn, ~p"/hosted/access/sessions")

    assert has_element?(view, ~s(a[data-method="delete"][href="/hosted/session"]))
    assert has_element?(view, ~s(a[data-method="delete"][href="/hosted/sessions"]))
    assert render(view) =~ "Every hosted session, including this one"
  end
end
