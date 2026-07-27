defmodule SddOrchestratorWeb.HostedAccessControllerTest do
  use SddOrchestratorWeb.ConnCase, async: true

  import Ecto.Query

  alias SddOrchestrator.Accounts.{HostedSession, MagicLinkAttempt}
  alias SddOrchestrator.HostedAccess.SessionCookie
  alias SddOrchestrator.HostedAccessFixtures
  alias SddOrchestrator.Repo

  describe "GET /hosted/access/verify" do
    test "consumes a valid link and issues the signed secure hosted-session cookie", %{conn: conn} do
      %{attempt: attempt, raw_token: raw_token} =
        HostedAccessFixtures.magic_link_attempt_fixture(email: "return@example.com")

      conn =
        conn
        |> put_req_header(
          "user-agent",
          "Mozilla/5.0 (X11; Linux x86_64) Gecko/20100101 Firefox/140.0"
        )
        |> get(~p"/hosted/access/verify?#{[attempt: attempt.id, token: raw_token]}")

      assert redirected_to(conn) == ~p"/?#{[hosted_access: "verified"]}"
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]

      cookie = conn.resp_cookies[SessionCookie.name()]
      assert cookie.http_only
      assert cookie.secure
      assert cookie.same_site == "Lax"
      assert cookie.max_age == 2_592_000

      session = Repo.one!(HostedSession)
      assert {:ok, session.token_digest} == SessionCookie.digest_from_signed(cookie.value)
      assert session.user_agent_family == "Firefox"
      assert session.os_family == "Linux"
      assert Repo.reload!(attempt).consumed_at != nil
    end

    test "missing, invalid, expired, and replayed returns share the same safe redirect", %{
      conn: conn
    } do
      expired =
        HostedAccessFixtures.magic_link_attempt_fixture(
          email: "expired-return@example.com",
          expires_at: DateTime.utc_now() |> DateTime.add(-1, :second)
        )

      valid =
        HostedAccessFixtures.magic_link_attempt_fixture(email: "replay-return@example.com")

      success =
        get(
          conn,
          ~p"/hosted/access/verify?#{[attempt: valid.attempt.id, token: valid.raw_token]}"
        )

      assert redirected_to(success) == ~p"/?#{[hosted_access: "verified"]}"

      failure_locations =
        [
          get(conn, ~p"/hosted/access/verify"),
          get(conn, ~p"/hosted/access/verify?#{[attempt: "bad", token: "bad"]}"),
          get(
            conn,
            ~p"/hosted/access/verify?#{[attempt: expired.attempt.id, token: expired.raw_token]}"
          ),
          get(
            conn,
            ~p"/hosted/access/verify?#{[attempt: valid.attempt.id, token: valid.raw_token]}"
          )
        ]
        |> Enum.map(&redirected_to/1)

      assert Enum.uniq(failure_locations) == [~p"/?#{[hosted_access: "invalid"]}"]
      assert Repo.aggregate(HostedSession, :count) == 1

      assert Repo.aggregate(
               from(attempt in MagicLinkAttempt,
                 where: not is_nil(attempt.consumed_at)
               ),
               :count
             ) == 1
    end
  end
end
