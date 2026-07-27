defmodule SddOrchestratorWeb.ContentSecurityPolicyTest do
  @moduledoc """
  Security proof for the strict Content-Security-Policy (Task 11): every browser
  response carries a same-origin CSP with a per-request nonce, and the only inline
  script — the device-local pre-paint theme script — carries the matching nonce so
  it runs while injected or third-party scripts are blocked.
  """
  use SddOrchestratorWeb.ConnCase, async: true

  test "sets a strict same-origin CSP with a per-request script nonce", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)

    assert [csp] = get_resp_header(conn, "content-security-policy")

    assert csp =~ "default-src 'self'"
    assert csp =~ "object-src 'none'"
    assert csp =~ "frame-ancestors 'none'"
    assert csp =~ "base-uri 'self'"
    refute csp =~ "unsafe-inline"
    refute csp =~ "unsafe-eval"

    assert [_, nonce] = Regex.run(~r/script-src 'self' 'nonce-([^']+)'/, csp)
    # The inline pre-paint theme script carries the same nonce, so it is allowed.
    assert html =~ ~s(nonce="#{nonce}")
  end

  test "issues a fresh nonce per request", %{conn: conn} do
    [csp1] = conn |> get(~p"/") |> get_resp_header("content-security-policy")
    [csp2] = build_conn() |> get(~p"/") |> get_resp_header("content-security-policy")

    assert csp1 != csp2
  end

  test "passwordless pages keep the same-origin policy and credential-safe referrer boundary",
       %{conn: conn} do
    conn = get(conn, ~p"/hosted/access")
    assert [csp] = get_resp_header(conn, "content-security-policy")
    assert csp =~ "default-src 'self'"
    assert csp =~ "connect-src 'self'"
    assert csp =~ "form-action 'self'"
    refute csp =~ "unsafe-inline"

    verification =
      build_conn()
      |> get(~p"/hosted/access/verify?#{[attempt: "invalid", token: "secret"]}")

    assert get_resp_header(verification, "cache-control") == ["no-store"]
    assert get_resp_header(verification, "referrer-policy") == ["no-referrer"]
    refute verification.resp_body =~ "secret"
  end
end
