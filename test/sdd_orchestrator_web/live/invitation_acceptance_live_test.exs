defmodule SddOrchestratorWeb.InvitationAcceptanceLiveTest do
  use SddOrchestratorWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias SddOrchestrator.Accounts.MagicLinkAttempt
  alias SddOrchestrator.HostedAccess.SessionCookie
  alias SddOrchestrator.Participation
  alias SddOrchestrator.Participation.Invitations
  alias SddOrchestrator.ParticipationDeliveryDouble
  alias SddOrchestrator.ParticipationFixtures
  alias SddOrchestrator.Repo

  setup do
    previous = Application.get_env(:sdd_orchestrator, :participation_email_delivery)

    Application.put_env(
      :sdd_orchestrator,
      :participation_email_delivery,
      ParticipationDeliveryDouble
    )

    ParticipationDeliveryDouble.succeed()

    on_exit(fn ->
      if previous do
        Application.put_env(:sdd_orchestrator, :participation_email_delivery, previous)
      else
        Application.delete_env(:sdd_orchestrator, :participation_email_delivery)
      end
    end)

    :ok
  end

  describe "opening the invitation link" do
    test "asks the invited person to confirm their own address", %{conn: conn} do
      %{project: project, invitation: invitation, token: token} = invited()

      {:ok, view, html} = live(conn, accept_path(invitation, token))

      assert html =~ project.name
      assert html =~ invitation.delivery_email
      assert html =~ "data-request-proof"
      refute html =~ "data-identity-change-warning"
      refute html =~ "data-proof-complete"

      requested = view |> element("[data-request-proof]") |> render_click()
      assert requested =~ "data-proof-requested"

      attempt = Repo.one!(MagicLinkAttempt)
      assert attempt.delivery_email == invitation.delivery_email
      assert attempt.return_to == "/projects/invitations/#{invitation.id}/accept"
    end

    test "shows the same safe result for an unusable link", %{conn: conn} do
      %{invitation: invitation, token: token} = invited()

      for path <- [
            accept_path(invitation, "wrong-token"),
            "/projects/invitations/#{Ecto.UUID.generate()}/accept?token=#{token}",
            "/projects/invitations/#{invitation.id}/accept"
          ] do
        {:ok, _view, html} = live(conn, path)
        assert html =~ "data-invitation-unavailable"
        refute html =~ invitation.delivery_email
      end
    end

    test "warns before replacing another active identity in this browser", %{conn: conn} do
      %{invitation: invitation, token: token} = invited()
      other = SddOrchestrator.HostedAccessFixtures.verified_hosted_session_fixture()

      {:ok, _view, html} =
        conn
        |> put_hosted_session(other.session_cookie)
        |> live(accept_path(invitation, token))

      assert html =~ "data-identity-change-warning"
      assert html =~ "data-request-proof"
      assert html =~ invitation.delivery_email
      refute html =~ "data-proof-complete"
      refute html =~ other.external_identity.display_identifier
    end

    test "confirms proof for the invited identity without granting access", %{conn: conn} do
      %{project: project, invitation: invitation, invitee: invitee} = invited()

      access =
        SddOrchestrator.HostedAccessFixtures.verified_hosted_session_fixture(%{
          email: invitation.delivery_email
        })

      {:ok, _view, html} =
        conn
        |> put_hosted_session(access.session_cookie)
        |> live("/projects/invitations/#{invitation.id}/accept")

      assert html =~ "data-proof-complete"
      assert html =~ "not on this project yet"
      refute html =~ "data-request-proof"

      refute Participation.active_participant(project.id, invitee.hosted_identity.id)
      assert Participation.active_participants(project.id) == []
    end
  end

  defp invited do
    result = ParticipationFixtures.hosted_project_fixture()

    ParticipationFixtures.member_profile_fixture(result.project, result.account, %{
      role: "owner",
      display_name: ParticipationFixtures.unique_display_name("Owner")
    })

    invitee = ParticipationFixtures.invited_identity_fixture()
    address = invitee.external_identity.display_identifier

    {:ok, %{invitation: invitation}} =
      Invitations.create(result.project, result.account.id, address)

    assert_received {:participation_email, email}
    [_, token] = Regex.run(~r/token=([A-Za-z0-9_-]+)/, email.text_body)

    Map.merge(result, %{invitation: invitation, token: token, invitee: invitee})
  end

  defp accept_path(invitation, token),
    do: "/projects/invitations/#{invitation.id}/accept?token=#{token}"

  defp put_hosted_session(conn, session_cookie) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(SessionCookie.session_key(), session_cookie.value)
  end
end
