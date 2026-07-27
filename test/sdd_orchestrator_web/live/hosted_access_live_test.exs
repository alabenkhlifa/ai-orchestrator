defmodule SddOrchestratorWeb.HostedAccessLiveTest do
  use SddOrchestratorWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias SddOrchestrator.Accounts.{HostedIdentity, MagicLinkAttempt}
  alias SddOrchestrator.HostedAccess
  alias SddOrchestrator.HostedAccess.RateLimiter
  alias SddOrchestrator.Repo

  setup do
    RateLimiter.reset()
    :ok
  end

  test "explains verified-email access, the recovery boundary, and neutral response", %{
    conn: conn
  } do
    {:ok, _view, html} =
      live(conn, ~p"/hosted/access?#{[return_to: "/onboarding/local"]}")

    assert html =~ "Verify your email to continue"
    assert html =~ "verified email is the access method"
    assert html =~ "linked beforehand"
    assert html =~ "Support can’t bypass"
    assert html =~ "same confirmation whether or not an account already exists"
    assert html =~ "No password is stored"
  end

  test "valid request shows the neutral waiting state without echoing the address", %{conn: conn} do
    {:ok, view, _html} =
      live(conn, ~p"/hosted/access?#{[return_to: "/onboarding/local"]}")

    html =
      view
      |> form("#hosted-access-form", %{"email" => "Private@Example.com"})
      |> render_submit()

    text = html |> LazyHTML.from_fragment() |> LazyHTML.text()

    assert text =~ "Check your email"
    assert text =~ "If the address can receive email"
    assert text =~ ~r/expires after 15\s+minutes/
    refute html =~ "Private@Example.com"

    attempt = Repo.one!(MagicLinkAttempt)
    assert attempt.email_key == "private@example.com"
    assert attempt.return_to == "/onboarding/local"
    assert Repo.aggregate(HostedIdentity, :count) == 0
  end

  test "new, existing, and invalid input render the same waiting acknowledgement", %{conn: conn} do
    assert {:ok, _existing} =
             HostedAccess.restore_or_create_identity("existing-ui@example.com")

    responses =
      for email <- ["existing-ui@example.com", "new-ui@example.com", "not an email"] do
        {:ok, view, _html} = live(conn, ~p"/hosted/access")

        view
        |> form("#hosted-access-form", %{"email" => email})
        |> render_submit()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#hosted-access-waiting")
        |> LazyHTML.text()
        |> String.replace(~r/\s+/, " ")
        |> String.trim()
      end

    assert length(Enum.uniq(responses)) == 1
    assert Repo.aggregate(MagicLinkAttempt, :count) == 2
    assert Repo.aggregate(HostedIdentity, :count) == 1
  end

  test "resend keeps only the newest attempt active and stays account-neutral", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/hosted/access")

    view
    |> form("#hosted-access-form", %{"email" => "resend-ui@example.com"})
    |> render_submit()

    first = Repo.one!(MagicLinkAttempt)

    html =
      view
      |> element("button", "Resend email")
      |> render_click()

    assert html =~ "another sign-in link is on its way"
    assert Repo.aggregate(MagicLinkAttempt, :count) == 2
    assert Repo.reload!(first).invalidated_at != nil

    assert Repo.aggregate(
             from(attempt in MagicLinkAttempt,
               where: is_nil(attempt.invalidated_at) and is_nil(attempt.consumed_at)
             ),
             :count
           ) == 1
  end

  test "use another email returns focusable request content without retaining the address", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/hosted/access")

    view
    |> form("#hosted-access-form", %{"email" => "another@example.com"})
    |> render_submit()

    html =
      view
      |> element("button", "Use another email")
      |> render_click()

    assert html =~ ~s(id="hosted-email")
    refute html =~ "another@example.com"
  end
end
