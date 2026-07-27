defmodule SddOrchestratorWeb.HostedAccessResultLiveTest do
  use SddOrchestratorWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias SddOrchestrator.HostedAccess.SessionCookie
  alias SddOrchestrator.HostedAccessFixtures

  test "shows verified success only when the signed hosted session resolves", %{conn: conn} do
    result =
      HostedAccessFixtures.verified_hosted_session_fixture(email: "result@example.com")

    conn =
      init_test_session(conn, %{
        SessionCookie.session_key() => result.session_cookie.value
      })

    {:ok, _view, html} =
      live(
        conn,
        ~p"/hosted/access/result?#{[status: "verified", return_to: "/onboarding/local"]}"
      )

    assert html =~ "Email verified"
    assert html =~ "across browser restarts"
    assert html =~ ~s(href="/onboarding/local")
    assert html =~ "Manage active sessions"
  end

  test "forged success and every ordinary failure show the same safe recovery state", %{
    conn: conn
  } do
    paths = [
      ~p"/hosted/access/result?#{[status: "verified"]}",
      ~p"/hosted/access/result?#{[status: "invalid"]}",
      ~p"/hosted/access/result?#{[status: "expired"]}"
    ]

    responses =
      Enum.map(paths, fn path ->
        {:ok, _view, html} = live(conn, path)

        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#hosted-access-invalid")
        |> LazyHTML.text()
        |> String.replace(~r/\s+/, " ")
        |> String.trim()
      end)

    assert length(Enum.uniq(responses)) == 1
    assert hd(responses) =~ "This sign-in link is no longer available"
    assert hd(responses) =~ "No hosted access was opened"
    assert hd(responses) =~ "Request a new link"
  end

  test "an external return destination is replaced with the safe hosted default", %{conn: conn} do
    result =
      HostedAccessFixtures.verified_hosted_session_fixture(email: "safe-return@example.com")

    conn =
      init_test_session(conn, %{
        SessionCookie.session_key() => result.session_cookie.value
      })

    {:ok, _view, html} =
      live(
        conn,
        ~p"/hosted/access/result?#{[status: "verified", return_to: "https://attacker.example"]}"
      )

    assert html =~ ~s(href="/hosted/access/sessions")
    refute html =~ "attacker.example"
  end
end
