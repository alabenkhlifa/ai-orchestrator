defmodule SddOrchestratorWeb.IdentityLinkLiveTest do
  @moduledoc """
  Integration proof for the identity-linking LiveView: the detected → verify →
  confirm steps, the explicit confirmation that commits the merge, the decline
  that keeps accounts separate, and the account-neutral redirect when there is
  nothing to link.
  """
  use SddOrchestratorWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import SddOrchestrator.AccountsFixtures
  import SddOrchestrator.HostedAccessFixtures

  alias SddOrchestrator.Accounts
  alias SddOrchestrator.IdentityLinking
  alias SddOrchestrator.IdentityLinking.IdentityMergeAttempt

  defp absorbed_with_candidate(email \\ "owner@example.com") do
    absorbed = account_fixture()
    Accounts.get_or_create_personal_workspace(absorbed)
    surviving = hosted_identity_fixture(email: email)
    {:ok, attempt} = IdentityLinking.start_merge_attempt(absorbed, email)
    %{absorbed: absorbed, surviving: surviving, attempt: attempt, email: email}
  end

  defp prove(attempt) do
    {:ok, %{challenge_id: cid, raw_token: token}} =
      IdentityLinking.request_passwordless_proof(attempt)

    {:ok, proven} = IdentityLinking.submit_passwordless_proof(cid, token)
    proven
  end

  test "the detected step offers verification and moves to the sent step", %{conn: conn} do
    %{absorbed: absorbed, attempt: attempt} = absorbed_with_candidate()
    conn = log_in_account(conn, absorbed)

    {:ok, view, html} = live(conn, "/identity/link/#{attempt.id}")
    assert html =~ "Link your GitHub sign-in"
    assert has_element?(view, "#link-step-detected")

    html = view |> element("button[phx-click=send_proof]") |> render_click()
    assert html =~ "Check your email"
    assert has_element?(view, "#link-step-sent")
  end

  test "confirming a proven attempt commits the merge and lands in the workspace", %{conn: conn} do
    %{absorbed: absorbed, surviving: surviving, attempt: attempt} = absorbed_with_candidate()
    _proven = prove(attempt)
    github_user_id = absorbed.github_identity.github_user_id
    conn = log_in_account(conn, absorbed)

    {:ok, view, _html} = live(conn, "/identity/link/#{attempt.id}")
    assert has_element?(view, "#link-step-confirm")

    view |> element("button[phx-click=confirm]") |> render_click()
    assert_redirect(view, "/projects")

    # The GitHub sign-in now resolves to the surviving passwordless account.
    assert Accounts.get_account_by_github_user_id(github_user_id).id == surviving.account.id
  end

  test "declining keeps the accounts separate", %{conn: conn} do
    %{absorbed: absorbed, attempt: attempt} = absorbed_with_candidate()
    github_user_id = absorbed.github_identity.github_user_id
    conn = log_in_account(conn, absorbed)

    {:ok, view, _html} = live(conn, "/identity/link/#{attempt.id}")
    view |> element("#link-step-detected button[phx-click=decline]") |> render_click()
    assert_redirect(view, "/projects")

    assert is_nil(IdentityLinking.get_live_attempt(attempt.id))
    # Still a standalone GitHub account; no merge occurred.
    assert Accounts.get_account_by_github_user_id(github_user_id).id == absorbed.id
  end

  test "an unknown or foreign attempt redirects account-neutrally", %{conn: conn} do
    absorbed = account_fixture()
    conn = log_in_account(conn, absorbed)

    assert {:error, {:live_redirect, %{to: "/projects"}}} =
             live(conn, "/identity/link/#{Ecto.UUID.generate()}")
  end

  test "another account cannot act on someone else's attempt", %{conn: conn} do
    %{attempt: attempt} = absorbed_with_candidate()
    intruder = account_fixture()
    conn = log_in_account(conn, intruder)

    assert {:error, {:live_redirect, %{to: "/projects"}}} =
             live(conn, "/identity/link/#{attempt.id}")

    # The attempt is untouched and still owned by its initiator.
    assert %IdentityMergeAttempt{} = IdentityLinking.get_live_attempt(attempt.id)
  end
end
