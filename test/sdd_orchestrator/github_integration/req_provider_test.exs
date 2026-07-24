defmodule SddOrchestrator.GitHubIntegration.ReqProviderTest do
  @moduledoc """
  Provider-contract proof for the real `Req` adapter using `Req.Test` stubs — no
  live GitHub. Locks the token parsing, error normalization, and the pinned API
  version header.
  """
  use ExUnit.Case, async: false

  alias SddOrchestrator.GitHubIntegration.ReqProvider

  @stub SddOrchestrator.GitHubIntegration.ReqProviderTest.Stub

  setup do
    original = Application.get_env(:sdd_orchestrator, :github)

    Application.put_env(
      :sdd_orchestrator,
      :github,
      Keyword.merge(original,
        provider: ReqProvider,
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
end
