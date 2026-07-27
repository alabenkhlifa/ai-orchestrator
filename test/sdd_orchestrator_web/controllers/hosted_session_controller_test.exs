defmodule SddOrchestratorWeb.HostedSessionControllerTest do
  use SddOrchestratorWeb.ConnCase, async: true

  alias SddOrchestrator.Accounts.HostedSession
  alias SddOrchestrator.HostedAccess.{SessionCookie, Sessions}
  alias SddOrchestrator.HostedAccessFixtures
  alias SddOrchestrator.Repo

  test "protected revocation routes reject a missing hosted session", %{conn: conn} do
    conn = delete(conn, ~p"/hosted/session")

    assert redirected_to(conn) == ~p"/?#{[hosted_access: "required"]}"
    assert conn.halted
  end

  test "normal sign-out revokes only the current browser session", %{conn: conn} do
    first = HostedAccessFixtures.verified_hosted_session_fixture(email: "sign-out@example.com")

    assert {:ok, second_session, second_cookie} =
             Sessions.create(first.hosted_identity, %{})

    conn =
      conn
      |> init_test_session(%{
        SessionCookie.session_key() => first.session_cookie.value
      })
      |> delete(~p"/hosted/session")

    assert redirected_to(conn) == ~p"/?#{[hosted_access: "signed_out"]}"
    assert get_session(conn, SessionCookie.session_key()) == nil
    assert :error = Sessions.authenticate(first.session_cookie.value)
    assert {:ok, _other_device} = Sessions.authenticate(second_cookie.value)
    refute Repo.get(HostedSession, first.session.id)
    assert Repo.get(HostedSession, second_session.id)
  end

  test "one-device revocation keeps the current and other device sessions valid", %{conn: conn} do
    current =
      HostedAccessFixtures.verified_hosted_session_fixture(email: "one-device@example.com")

    assert {:ok, target_session, target_cookie} =
             Sessions.create(current.hosted_identity, %{})

    assert {:ok, other_session, other_cookie} =
             Sessions.create(current.hosted_identity, %{})

    conn =
      conn
      |> init_test_session(%{
        SessionCookie.session_key() => current.session_cookie.value
      })
      |> delete(~p"/hosted/sessions/#{target_session.id}")

    assert redirected_to(conn) == ~p"/?#{[hosted_access: "session_revoked"]}"
    assert {:ok, _current} = Sessions.authenticate(current.session_cookie.value)
    assert :error = Sessions.authenticate(target_cookie.value)
    assert {:ok, _other} = Sessions.authenticate(other_cookie.value)
    assert Repo.get(HostedSession, current.session.id)
    refute Repo.get(HostedSession, target_session.id)
    assert Repo.get(HostedSession, other_session.id)
  end

  test "all-device sign-out revokes every session and clears this browser", %{conn: conn} do
    current =
      HostedAccessFixtures.verified_hosted_session_fixture(email: "all-devices@example.com")

    assert {:ok, _other_session, other_cookie} =
             Sessions.create(current.hosted_identity, %{})

    conn =
      conn
      |> init_test_session(%{
        SessionCookie.session_key() => current.session_cookie.value
      })
      |> delete(~p"/hosted/sessions")

    assert redirected_to(conn) == ~p"/?#{[hosted_access: "signed_out_all"]}"
    assert get_session(conn, SessionCookie.session_key()) == nil
    assert :error = Sessions.authenticate(current.session_cookie.value)
    assert :error = Sessions.authenticate(other_cookie.value)
    assert Repo.aggregate(HostedSession, :count) == 0
  end
end
