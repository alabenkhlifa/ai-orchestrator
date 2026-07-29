defmodule SddOrchestratorWeb.ParticipationLiveTest do
  use SddOrchestratorWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions

  alias SddOrchestrator.Participation
  alias SddOrchestrator.Participation.{Invitations, ProjectInvitation}
  alias SddOrchestrator.ParticipationFixtures
  alias SddOrchestrator.Repo

  describe "owner profile prerequisite" do
    test "blocks invitations until the owner saves a project display name", %{conn: conn} do
      %{project: project, account: account} = ParticipationFixtures.hosted_project_fixture()

      {:ok, view, html} =
        conn |> log_in_account(account) |> live(~p"/projects/#{project.id}/participation")

      assert html =~ "data-owner-profile-required"
      assert html =~ "data-invitations-unavailable"
      refute html =~ "data-invitations-available"
      refute Participation.owner_profile_established?(project.id)

      html =
        view
        |> form("#owner-profile-form", owner: %{display_name: "  Ada Lovelace  "})
        |> render_submit()

      assert html =~ "data-owner-profile-saved"
      assert html =~ "data-invitations-available"
      refute html =~ "data-invitations-unavailable"
      assert html =~ "Ada Lovelace"

      profile = Participation.owner_profile(project.id)
      assert profile.display_name == "Ada Lovelace"
      assert profile.display_name_key == "ada lovelace"
      assert profile.role == "owner"
      assert profile.account_id == account.id
      assert Participation.owner_profile_established?(project.id)
    end

    test "labels the owner by project name, never by email", %{conn: conn} do
      %{project: project, account: account, owner: owner} =
        ParticipationFixtures.hosted_project_fixture()

      ParticipationFixtures.member_profile_fixture(project, account, %{
        role: "owner",
        display_name: "Grace Hopper"
      })

      {:ok, view, html} =
        conn |> log_in_account(account) |> live(~p"/projects/#{project.id}/participation")

      assert html =~ "Grace Hopper"
      refute html =~ "data-owner-profile-required"

      # The label is the project display name; the address appears only in the
      # owner's own membership-management column.
      assert view |> element("[data-member-name]") |> render() =~ "Grace Hopper"
      refute view |> element("[data-member-name]") |> render() =~ "@example.com"

      assert view |> element("[data-member-email]") |> render() =~
               owner.external_identity.display_identifier
    end
  end

  describe "owner self-edit" do
    test "corrects the label while preserving identity and ownership", %{conn: conn} do
      %{project: project, account: account} = ParticipationFixtures.hosted_project_fixture()

      profile =
        ParticipationFixtures.member_profile_fixture(project, account, %{
          role: "owner",
          display_name: "First Label"
        })

      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(~p"/projects/#{project.id}/participation")

      html =
        view
        |> form("#owner-profile-form", owner: %{display_name: "Second Label"})
        |> render_submit()

      assert html =~ "Second Label"
      assert html =~ "data-owner-profile-saved"

      updated = Participation.owner_profile(project.id)
      assert updated.id == profile.id
      assert updated.account_id == account.id
      assert updated.display_name == "Second Label"
      assert {:ok, owner} = Participation.owner(project)
      assert owner.account_id == account.id
    end

    test "rejects a conflicting label inline without an automatic suffix", %{conn: conn} do
      %{project: project, account: account} = ParticipationFixtures.hosted_project_fixture()
      participant = ParticipationFixtures.invited_identity_fixture()

      ParticipationFixtures.member_profile_fixture(project, participant.account, %{
        role: "participant",
        display_name: "Ada Lovelace"
      })

      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(~p"/projects/#{project.id}/participation")

      html =
        view
        |> form("#owner-profile-form", owner: %{display_name: "ADA lovelace"})
        |> render_submit()

      assert html =~ "is already used in this project"
      refute html =~ "data-owner-profile-saved"
      refute Participation.owner_profile_established?(project.id)

      # The rejected input is returned for correction, never renamed for the user.
      assert html =~ "ADA lovelace"
      refute html =~ "ADA lovelace 2"
    end

    test "rejects blank and email-shaped labels", %{conn: conn} do
      %{project: project, account: account} = ParticipationFixtures.hosted_project_fixture()

      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(~p"/projects/#{project.id}/participation")

      for invalid <- ["", "   ", "owner@example.com", String.duplicate("n", 81)] do
        html =
          view
          |> form("#owner-profile-form", owner: %{display_name: invalid})
          |> render_submit()

        assert html =~ ~s(aria-invalid="true")
        refute html =~ "data-owner-profile-saved"
        refute Participation.owner_profile_established?(project.id)
      end

      # An email address is rejected as a project label rather than accepted as
      # an email-derived owner name.
      html =
        view
        |> form("#owner-profile-form", owner: %{display_name: "owner@example.com"})
        |> render_submit()

      assert html =~ "is not an available project label"
    end
  end

  describe "authorization" do
    test "returns another account to the catalog without exposing the project", %{conn: conn} do
      %{project: project} = ParticipationFixtures.hosted_project_fixture()
      %{account: other_account} = ParticipationFixtures.hosted_project_fixture()

      assert {:error, {:live_redirect, %{to: "/projects"}}} =
               conn
               |> log_in_account(other_account)
               |> live(~p"/projects/#{project.id}/participation")
    end

    test "returns an unknown or malformed project to the catalog", %{conn: conn} do
      %{account: account} = ParticipationFixtures.hosted_project_fixture()

      assert {:error, {:live_redirect, %{to: "/projects"}}} =
               conn
               |> log_in_account(account)
               |> live(~p"/projects/#{Ecto.UUID.generate()}/participation")

      assert {:error, {:live_redirect, %{to: "/projects"}}} =
               conn |> log_in_account(account) |> live(~p"/projects/not-a-project/participation")
    end

    test "fails closed for a visitor with no session" do
      %{project: project} = ParticipationFixtures.hosted_project_fixture()

      assert {:error, {:live_redirect, %{to: "/projects"}}} =
               build_conn() |> live(~p"/projects/#{project.id}/participation")
    end

    test "denies a non-owner through the domain action itself" do
      %{project: project} = ParticipationFixtures.hosted_project_fixture()
      %{account: other_account} = ParticipationFixtures.hosted_project_fixture()

      assert {:error, :unauthorized} =
               Participation.save_owner_profile(project, other_account.id, "Intruder Label")

      assert {:error, :unauthorized} = Participation.save_owner_profile(project, nil, "Label")
      refute Participation.owner_profile_established?(project.id)
    end
  end

  describe "invitation form" do
    test "appears only after the owner profile exists and sends one invitation", %{conn: conn} do
      %{project: project, account: account} = ParticipationFixtures.hosted_project_fixture()

      {:ok, view, html} =
        conn |> log_in_account(account) |> live(~p"/projects/#{project.id}/participation")

      refute html =~ ~s(id="invitation-form")

      view
      |> form("#owner-profile-form", owner: %{display_name: "Ada Lovelace"})
      |> render_submit()

      html =
        view
        |> form("#invitation-form", invite: %{email: "invitee@example.com"})
        |> render_submit()

      assert html =~ "data-invitation-sent"
      # Membership management shows the owner which address was invited.
      assert html =~ "data-invitation-list"
      assert html =~ "invitee@example.com"

      invitation = Invitations.pending_for(project.id, "invitee@example.com")
      assert invitation.project_id == project.id
      assert invitation.status == "pending"
      assert_email_sent(fn email -> email.to == [{"", "invitee@example.com"}] end)
    end

    test "returns an inline result for an invalid or duplicate address", %{conn: conn} do
      %{project: project, account: account} = ParticipationFixtures.hosted_project_fixture()

      ParticipationFixtures.member_profile_fixture(project, account, %{
        role: "owner",
        display_name: "Ada Lovelace"
      })

      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(~p"/projects/#{project.id}/participation")

      html = view |> form("#invitation-form", invite: %{email: "invitee"}) |> render_submit()

      assert html =~ "Enter a complete email address."
      assert html =~ ~s(aria-invalid="true")
      refute html =~ "data-invitation-sent"
      refute Invitations.pending_for(project.id, "invitee")

      view
      |> form("#invitation-form", invite: %{email: "invitee@example.com"})
      |> render_submit()

      duplicate =
        view
        |> form("#invitation-form", invite: %{email: "INVITEE@example.com"})
        |> render_submit()

      assert duplicate =~ "already has a pending invitation"
      assert Repo.aggregate(ProjectInvitation, :count) == 1
    end

    test "offers an inline replacement link when one is already pending", %{conn: conn} do
      %{project: project, account: account} = ParticipationFixtures.hosted_project_fixture()

      ParticipationFixtures.member_profile_fixture(project, account, %{
        role: "owner",
        display_name: "Ada Lovelace"
      })

      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(~p"/projects/#{project.id}/participation")

      view |> form("#invitation-form", invite: %{email: "invitee@example.com"}) |> render_submit()

      duplicate =
        view
        |> form("#invitation-form", invite: %{email: "invitee@example.com"})
        |> render_submit()

      assert duplicate =~ "data-resend-invitation"
      original = Invitations.pending_for(project.id, "invitee@example.com")

      replaced = view |> element("[data-resend-invitation]") |> render_click()

      assert replaced =~ "data-invitation-sent"
      refute replaced =~ "data-resend-invitation"

      rotated = Invitations.pending_for(project.id, "invitee@example.com")
      assert rotated.id == original.id
      assert rotated.credential_version == 2
      assert rotated.token_digest != original.token_digest
      assert Repo.aggregate(ProjectInvitation, :count) == 1
    end

    test "cancels the pending invitation inline and requires a fresh flow", %{conn: conn} do
      %{project: project, account: account} = ParticipationFixtures.hosted_project_fixture()

      ParticipationFixtures.member_profile_fixture(project, account, %{
        role: "owner",
        display_name: "Ada Lovelace"
      })

      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(~p"/projects/#{project.id}/participation")

      view |> form("#invitation-form", invite: %{email: "invitee@example.com"}) |> render_submit()

      duplicate =
        view
        |> form("#invitation-form", invite: %{email: "invitee@example.com"})
        |> render_submit()

      assert duplicate =~ "data-cancel-invitation"
      original = Invitations.pending_for(project.id, "invitee@example.com")

      canceled = view |> element("[data-cancel-invitation]") |> render_click()

      assert canceled =~ "data-invitation-canceled"
      refute canceled =~ "data-cancel-invitation"
      refute Invitations.pending_for(project.id, "invitee@example.com")

      ended = Repo.get!(ProjectInvitation, original.id)
      assert ended.status == "canceled"
      assert is_nil(ended.token_digest)
    end

    test "keeps the invitation control full width on small screens", %{conn: conn} do
      %{project: project, account: account} = ParticipationFixtures.hosted_project_fixture()

      ParticipationFixtures.member_profile_fixture(project, account, %{
        role: "owner",
        display_name: "Ada Lovelace"
      })

      {:ok, _view, html} =
        conn |> log_in_account(account) |> live(~p"/projects/#{project.id}/participation")

      assert html =~ ~s(<label for="invite-email")
      assert html =~ ~s(data-send-invitation)
      assert html =~ "w-full sm:w-auto"
    end
  end

  describe "identity visibility" do
    setup do
      previous = Application.get_env(:sdd_orchestrator, :participation_email_delivery)

      Application.put_env(
        :sdd_orchestrator,
        :participation_email_delivery,
        SddOrchestrator.ParticipationDeliveryDouble
      )

      SddOrchestrator.ParticipationDeliveryDouble.succeed()

      on_exit(fn ->
        if previous do
          Application.put_env(:sdd_orchestrator, :participation_email_delivery, previous)
        else
          Application.delete_env(:sdd_orchestrator, :participation_email_delivery)
        end
      end)

      :ok
    end

    test "the owner sees every member label and address", %{conn: conn} do
      %{project: project, account: account, owner: owner, participants: [first, second]} =
        project_with_participants()

      {:ok, view, html} =
        conn |> log_in_account(account) |> live(~p"/projects/#{project.id}/participation")

      rendered = view |> element("[data-members]") |> render()

      for label <- ["Owner Label", "First Member", "Second Member"] do
        assert rendered =~ label
      end

      for address <- [
            owner.external_identity.display_identifier,
            first.external_identity.display_identifier,
            second.external_identity.display_identifier
          ] do
        assert rendered =~ address
      end

      assert html =~ ~s(id="invitation-form")
      assert html =~ ~s(id="owner-profile-form")
    end

    test "a participant sees labels and only their own address", %{conn: conn} do
      %{project: project, owner: owner, participants: [first, second]} =
        project_with_participants()

      access =
        SddOrchestrator.HostedAccessFixtures.verified_hosted_session_fixture(%{
          email: first.external_identity.display_identifier
        })

      {:ok, view, html} =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> Plug.Conn.put_session(
          SddOrchestrator.HostedAccess.SessionCookie.session_key(),
          access.session_cookie.value
        )
        |> live(~p"/projects/#{project.id}/participation")

      rendered = view |> element("[data-members]") |> render()

      for label <- ["Owner Label", "First Member", "Second Member"] do
        assert rendered =~ label
      end

      assert rendered =~ first.external_identity.display_identifier
      refute rendered =~ owner.external_identity.display_identifier
      refute rendered =~ second.external_identity.display_identifier

      # Management belongs to the owner alone.
      assert html =~ "data-participant-view"
      refute html =~ ~s(id="invitation-form")
      refute html =~ ~s(id="owner-profile-form")
      refute html =~ "data-invitation-list"
    end

    test "the owner removes a participant inline and access ends", %{conn: conn} do
      %{project: project, account: account, participants: [first, second]} =
        project_with_participants()

      {:ok, view, html} =
        conn |> log_in_account(account) |> live(~p"/projects/#{project.id}/participation")

      assert html =~ "data-remove-member"

      removed =
        view
        |> element("[data-remove-member][phx-value-account=\"#{first.account.id}\"]")
        |> render_click()

      assert removed =~ "data-member-removed"
      refute removed =~ "First Member"
      assert removed =~ "Second Member"

      refute Participation.active_participant(project.id, first.hosted_identity.id)
      assert Participation.active_participant(project.id, second.hosted_identity.id)

      assert [revocation] = SddOrchestrator.Participation.Revocations.pending()
      assert revocation.project_id == project.id
      assert revocation.reason == "removed"
      assert revocation.last_display_name == "First Member"
    end

    test "a participant edits only their own label inline", %{conn: conn} do
      %{project: project, participants: [first, _second]} = project_with_participants()

      access =
        SddOrchestrator.HostedAccessFixtures.verified_hosted_session_fixture(%{
          email: first.external_identity.display_identifier
        })

      {:ok, view, html} =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> Plug.Conn.put_session(
          SddOrchestrator.HostedAccess.SessionCookie.session_key(),
          access.session_cookie.value
        )
        |> live(~p"/projects/#{project.id}/participation")

      assert html =~ ~s(id="member-profile-form")
      assert html =~ "First Member"

      saved =
        view
        |> form("#member-profile-form", owner: %{display_name: "  Renamed Member  "})
        |> render_submit()

      assert saved =~ "data-member-profile-saved"
      assert saved =~ "Renamed Member"

      assert Participation.member_profile(project.id, first.account.id).display_name ==
               "Renamed Member"

      conflict =
        view
        |> form("#member-profile-form", owner: %{display_name: "second member"})
        |> render_submit()

      assert conflict =~ "is already used in this project"
      refute conflict =~ "second member 2"

      assert Participation.member_profile(project.id, first.account.id).display_name ==
               "Renamed Member"
    end

    test "a participant can leave and immediately loses access", %{conn: conn} do
      %{project: project, participants: [first, second]} = project_with_participants()

      access =
        SddOrchestrator.HostedAccessFixtures.verified_hosted_session_fixture(%{
          email: first.external_identity.display_identifier
        })

      conn = hosted_conn(conn, access)

      {:ok, view, html} = live(conn, ~p"/projects/#{project.id}/participation")
      assert html =~ "data-leave-project"

      assert {:error, {:live_redirect, %{to: "/projects"}}} =
               view |> element("[data-leave-project]") |> render_click()

      refute Participation.active_participant(project.id, first.hosted_identity.id)
      assert Participation.active_participant(project.id, second.hosted_identity.id)

      assert [revocation] = SddOrchestrator.Participation.Revocations.pending()
      assert revocation.reason == "left"

      # Returning is fail-closed, not a resumed session.
      assert {:error, {:live_redirect, %{to: "/projects"}}} =
               live(hosted_conn(build_conn(), access), ~p"/projects/#{project.id}/participation")
    end

    test "the owner has no leave control", %{conn: conn} do
      %{project: project, account: account} = project_with_participants()

      {:ok, _view, html} =
        conn |> log_in_account(account) |> live(~p"/projects/#{project.id}/participation")

      refute html =~ "data-leave-project"
    end

    test "a former participant and an outsider fail closed", %{conn: conn} do
      %{project: project, participants: [first, _second]} = project_with_participants()

      participant =
        Participation.active_participant(project.id, first.hosted_identity.id)

      {:ok, _departed} =
        participant
        |> SddOrchestrator.Participation.ProjectParticipant.departure_changeset(%{
          departure_reason: "removed"
        })
        |> Repo.update()

      access =
        SddOrchestrator.HostedAccessFixtures.verified_hosted_session_fixture(%{
          email: first.external_identity.display_identifier
        })

      assert {:error, {:live_redirect, %{to: "/projects"}}} =
               conn
               |> Phoenix.ConnTest.init_test_session(%{})
               |> Plug.Conn.put_session(
                 SddOrchestrator.HostedAccess.SessionCookie.session_key(),
                 access.session_cookie.value
               )
               |> live(~p"/projects/#{project.id}/participation")
    end
  end

  defp hosted_conn(conn, access) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(
      SddOrchestrator.HostedAccess.SessionCookie.session_key(),
      access.session_cookie.value
    )
  end

  defp project_with_participants do
    result = ParticipationFixtures.hosted_project_fixture()

    ParticipationFixtures.member_profile_fixture(result.project, result.account, %{
      role: "owner",
      display_name: "Owner Label"
    })

    participants =
      for label <- ["First Member", "Second Member"] do
        identity = ParticipationFixtures.invited_identity_fixture()
        ParticipationFixtures.participant_fixture(result.project, identity.hosted_identity)

        ParticipationFixtures.member_profile_fixture(result.project, identity.account, %{
          role: "participant",
          display_name: label
        })

        identity
      end

    Map.put(result, :participants, participants)
  end

  describe "accessible form structure" do
    test "labels the control and links its inline error", %{conn: conn} do
      %{project: project, account: account} = ParticipationFixtures.hosted_project_fixture()

      {:ok, view, html} =
        conn |> log_in_account(account) |> live(~p"/projects/#{project.id}/participation")

      assert html =~ ~s(<label for="owner-display-name")
      assert html =~ ~s(id="owner-display-name")
      assert html =~ ~s(aria-describedby="owner-display-name-hint")

      invalid =
        view |> form("#owner-profile-form", owner: %{display_name: ""}) |> render_submit()

      assert invalid =~ ~s(aria-invalid="true")
      assert invalid =~ ~s(aria-describedby="owner-display-name-error")
      assert invalid =~ ~s(id="owner-display-name-error")
    end

    test "uses full-width mobile actions that grow on wider screens", %{conn: conn} do
      %{project: project, account: account} = ParticipationFixtures.hosted_project_fixture()

      {:ok, _view, html} =
        conn |> log_in_account(account) |> live(~p"/projects/#{project.id}/participation")

      assert html =~ "w-full sm:w-auto"
      assert html =~ "flex flex-col gap-3 sm:flex-row"
    end
  end
end
