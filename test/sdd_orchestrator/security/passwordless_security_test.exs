defmodule SddOrchestrator.Security.PasswordlessSecurityTest do
  @moduledoc """
  Passwordless secret-surface proof for Task 7: protected structs, request logs,
  redirect payloads, and browser cookie attributes do not expose magic-link or
  hosted-session credentials.
  """
  use SddOrchestratorWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias SddOrchestrator.HostedAccess.SessionCookie
  alias SddOrchestrator.HostedAccessFixtures

  test "protected authentication structs omit personal identifiers and credentials" do
    result =
      HostedAccessFixtures.verified_hosted_session_fixture(%{
        email: "inspect-secret@example.com"
      })

    attempt_dump = inspect(result.attempt)
    session_dump = inspect(result.session)
    cookie_dump = inspect(result.session_cookie)

    refute attempt_dump =~ "inspect-secret@example.com"
    refute attempt_dump =~ Base.encode64(result.attempt.token_digest)
    refute attempt_dump =~ Base.encode64(result.attempt.token_salt)
    refute session_dump =~ Base.encode64(result.session.token_digest)
    refute cookie_dump =~ result.session_cookie.value
  end

  test "verification strips the delivered credential and writes only a secure browser cookie",
       %{conn: conn} do
    fixture =
      HostedAccessFixtures.magic_link_attempt_fixture(%{
        email: "browser-secret@example.com"
      })

    parent = self()

    log =
      capture_log([level: :info], fn ->
        response =
          get(
            conn,
            ~p"/hosted/access/verify?#{[attempt: fixture.attempt.id, token: fixture.raw_token]}"
          )

        send(parent, {:verification_response, response})
      end)

    assert_receive {:verification_response, response}
    assert redirected_to(response) =~ "/hosted/access/result"

    [set_cookie] = get_resp_header(response, "set-cookie")
    assert set_cookie =~ "secure"
    assert set_cookie =~ "HttpOnly"
    assert set_cookie =~ "SameSite=Lax"

    for exposed_surface <- [
          response.resp_body,
          redirected_to(response),
          log,
          inspect(response.assigns)
        ] do
      refute exposed_surface =~ fixture.raw_token
      refute exposed_surface =~ "browser-secret@example.com"
    end

    refute response.resp_body =~ set_cookie
  end

  test "passwordless logging statements contain no identifiers or credential variables" do
    source =
      "lib/sdd_orchestrator/hosted_access"
      |> Path.join("**/*.ex")
      |> Path.wildcard()
      |> Enum.map_join("\n", &File.read!/1)

    logger_statements =
      source
      |> String.split("\n")
      |> Enum.filter(&String.contains?(&1, "Logger."))
      |> Enum.join("\n")

    refute logger_statements =~ "raw_token"
    refute logger_statements =~ "delivery_email"
    refute logger_statements =~ "email_key"
    refute logger_statements =~ "attempt.id"
    refute logger_statements =~ "session_cookie"
  end

  test "the hosted session cookie wrapper never exposes its credential through inspection" do
    {_digest, cookie} = SessionCookie.issue()

    refute inspect(cookie) =~ cookie.value
    assert inspect(cookie) == "#SddOrchestrator.HostedAccess.SessionCookie<...>"
  end
end
