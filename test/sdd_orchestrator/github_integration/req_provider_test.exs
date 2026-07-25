defmodule SddOrchestrator.GitHubIntegration.ReqProviderTest do
  @moduledoc """
  Provider-contract proof for the real `Req` adapter using `Req.Test` stubs — no
  live GitHub. Locks token parsing, the pinned API version header, `Link`-header
  pagination, HTTP-error normalization (401 → unauthorized, 403 → rate-limit vs
  organization restriction), and the app-JWT-authenticated pending-request read.
  """
  use ExUnit.Case, async: false

  alias SddOrchestrator.GitHubIntegration.ReqProvider

  @stub SddOrchestrator.GitHubIntegration.ReqProviderTest.Stub

  setup_all do
    # A throwaway RSA key so the app-JWT signing path is exercised without a live
    # GitHub App or a committed key.
    jwk = JOSE.JWK.generate_key({:rsa, 2048})
    {_meta, pem} = JOSE.JWK.to_pem(jwk)
    %{app_private_key: pem}
  end

  setup %{app_private_key: pem} do
    original = Application.get_env(:sdd_orchestrator, :github)

    Application.put_env(
      :sdd_orchestrator,
      :github,
      Keyword.merge(original,
        provider: ReqProvider,
        client_id: "test-client-id",
        app_private_key: pem,
        token_url: "https://github.test/login/oauth/access_token",
        api_base_url: "https://api.github.test",
        req_options: [plug: {Req.Test, @stub}]
      )
    )

    on_exit(fn -> Application.put_env(:sdd_orchestrator, :github, original) end)
    :ok
  end

  test "exchange_code/2 parses a token set" do
    Req.Test.stub(@stub, fn conn ->
      Req.Test.json(conn, %{
        "access_token" => "gho_abc",
        "refresh_token" => "ghr_abc",
        "expires_in" => 28_800,
        "scope" => "repo"
      })
    end)

    assert {:ok, token} = ReqProvider.exchange_code("the-code", "the-verifier")
    assert token.access_token == "gho_abc"
    assert token.refresh_token == "ghr_abc"
    assert token.scope == "repo"
  end

  test "exchange_code/2 normalizes an OAuth error body" do
    Req.Test.stub(@stub, fn conn -> Req.Test.json(conn, %{"error" => "bad_verification_code"}) end)

    assert {:error, {:oauth, "bad_verification_code"}} = ReqProvider.exchange_code("c", "v")
  end

  test "get_user/1 pins the API version and parses the identity" do
    Req.Test.stub(@stub, fn conn ->
      assert Plug.Conn.get_req_header(conn, "x-github-api-version") == ["2026-03-10"]
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer gho_abc"]
      Req.Test.json(conn, %{"id" => 99, "login" => "octocat", "avatar_url" => "https://a/x.png"})
    end)

    assert {:ok, user} = ReqProvider.get_user("gho_abc")
    assert user.id == 99
    assert user.login == "octocat"
  end

  test "get_user/1 maps a 401 to :unauthorized" do
    Req.Test.stub(@stub, fn conn -> Plug.Conn.send_resp(conn, 401, "unauthorized") end)
    assert {:error, :unauthorized} = ReqProvider.get_user("bad")
  end

  describe "list_user_installations/1" do
    test "follows Link pagination and normalizes installations" do
      Req.Test.stub(@stub, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        case conn.query_params["page"] do
          nil ->
            conn
            |> Plug.Conn.put_resp_header(
              "link",
              ~s(<https://api.github.test/user/installations?per_page=100&page=2>; rel="next")
            )
            |> Req.Test.json(%{
              "installations" => [
                %{
                  "id" => 1,
                  "account" => %{"login" => "octo", "type" => "User"},
                  "permissions" => %{"metadata" => "read"}
                }
              ]
            })

          "2" ->
            Req.Test.json(conn, %{
              "installations" => [
                %{
                  "id" => 2,
                  "account" => %{"login" => "acme", "type" => "Organization"},
                  "permissions" => %{"metadata" => "read"}
                }
              ]
            })
        end
      end)

      assert {:ok, installations} = ReqProvider.list_user_installations("gho_user")
      assert Enum.map(installations, & &1.id) == [1, 2]
      assert Enum.map(installations, & &1.account_type) == ["User", "Organization"]
    end

    test "maps a 403 with an exhausted rate limit to :rate_limited" do
      Req.Test.stub(@stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("x-ratelimit-remaining", "0")
        |> Plug.Conn.send_resp(403, "rate limited")
      end)

      assert {:error, :rate_limited} = ReqProvider.list_user_installations("gho_user")
    end

    test "maps a 403 without rate-limit exhaustion to :org_restricted" do
      Req.Test.stub(@stub, fn conn -> Plug.Conn.send_resp(conn, 403, "SSO required") end)
      assert {:error, :org_restricted} = ReqProvider.list_user_installations("gho_user")
    end
  end

  describe "list_installation_repositories/2" do
    test "pins the API version and normalizes repository metadata" do
      Req.Test.stub(@stub, fn conn ->
        assert Plug.Conn.get_req_header(conn, "x-github-api-version") == ["2026-03-10"]

        Req.Test.json(conn, %{
          "repositories" => [
            %{
              "id" => 501,
              "name" => "roadmap",
              "full_name" => "acme/roadmap",
              "private" => true,
              "visibility" => "private",
              "html_url" => "https://github.com/acme/roadmap",
              "owner" => %{"login" => "acme", "type" => "Organization"}
            }
          ]
        })
      end)

      assert {:ok, [repo]} = ReqProvider.list_installation_repositories("gho_user", 2)
      assert repo.id == 501
      assert repo.private
      assert repo.organization == "acme"
      assert repo.owner_type == "Organization"
    end

    test "maps a 401 to :unauthorized" do
      Req.Test.stub(@stub, fn conn -> Plug.Conn.send_resp(conn, 401, "unauthorized") end)
      assert {:error, :unauthorized} = ReqProvider.list_installation_repositories("bad", 1)
    end
  end

  describe "list_pending_installation_requests/0" do
    test "signs an app JWT and normalizes pending requests" do
      Req.Test.stub(@stub, fn conn ->
        assert [<<"Bearer ", jwt::binary>>] = Plug.Conn.get_req_header(conn, "authorization")
        # A signed JWS is three base64url segments; the header starts with eyJ.
        assert String.starts_with?(jwt, "eyJ")
        assert length(String.split(jwt, ".")) == 3

        Req.Test.json(conn, [
          %{"id" => 7, "account" => %{"login" => "acme"}, "requester" => %{"id" => 42}}
        ])
      end)

      assert {:ok, [request]} = ReqProvider.list_pending_installation_requests()
      assert request.id == 7
      assert request.account_login == "acme"
      assert request.requester_id == 42
    end

    test "returns an error when no private key is configured" do
      cfg = Application.get_env(:sdd_orchestrator, :github)
      Application.put_env(:sdd_orchestrator, :github, Keyword.delete(cfg, :app_private_key))
      on_exit(fn -> Application.put_env(:sdd_orchestrator, :github, cfg) end)

      assert {:error, {:app_jwt, :missing_private_key}} =
               ReqProvider.list_pending_installation_requests()
    end
  end
end
