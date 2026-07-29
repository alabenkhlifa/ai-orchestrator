defmodule SddOrchestrator.Participation.InvitationProofTest do
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Accounts.MagicLinkAttempt
  alias SddOrchestrator.HostedAccess
  alias SddOrchestrator.HostedAccess.Sessions
  alias SddOrchestrator.Participation
  alias SddOrchestrator.Participation.{InvitationProof, Invitations, ProjectInvitation}
  alias SddOrchestrator.ParticipationDeliveryDouble
  alias SddOrchestrator.ParticipationFixtures

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

  describe "open/3" do
    test "resolves a usable invitation from its delivered credential" do
      %{project: project, invitation: invitation, token: token} = invited()

      assert {:ok, opened} = InvitationProof.open(invitation.id, token)
      assert opened.invitation.id == invitation.id
      assert opened.project.id == project.id
      assert opened.invited_email == invitation.delivery_email
    end

    test "returns the same safe result for every unusable case" do
      %{account: account, project: project, invitation: invitation, token: token} = invited()

      assert {:error, :invalid_or_expired} = InvitationProof.open(invitation.id, "wrong-token")
      assert {:error, :invalid_or_expired} = InvitationProof.open(Ecto.UUID.generate(), token)
      assert {:error, :invalid_or_expired} = InvitationProof.open("not-an-id", token)
      assert {:error, :invalid_or_expired} = InvitationProof.open(invitation.id, nil)

      past = DateTime.add(invitation.expires_at, 1, :second)
      assert {:error, :invalid_or_expired} = InvitationProof.open(invitation.id, token, past)

      {:ok, _canceled} =
        Invitations.cancel(project, account.id, invitation.delivery_email)

      assert {:error, :invalid_or_expired} = InvitationProof.open(invitation.id, token)
    end

    test "a replaced credential stops opening the invitation" do
      %{account: account, project: project, invitation: invitation, token: token} = invited()

      {:ok, _resent} = Invitations.resend(project, account.id, invitation.delivery_email)

      assert {:error, :invalid_or_expired} = InvitationProof.open(invitation.id, token)
    end
  end

  describe "proof_state/2" do
    test "treats an absent or different identity as unproven" do
      %{invitation: invitation} = invited()
      other = ParticipationFixtures.invited_identity_fixture()

      assert InvitationProof.proof_state(invitation, nil) == :proof_required
      assert InvitationProof.proof_state(invitation, other.hosted_identity) == :different_email
    end

    test "recognizes the identity that verified the invited address" do
      %{invitation: invitation, invitee: invitee} = invited()

      assert InvitationProof.proof_state(invitation, invitee.hosted_identity) == :proven
    end
  end

  describe "request/2" do
    test "requests proof for the invited address, never for typed input" do
      %{invitation: invitation, token: token} = invited()
      {:ok, opened} = InvitationProof.open(invitation.id, token)

      assert {:ok, %{status: :accepted}} = InvitationProof.request(opened)

      attempt =
        MagicLinkAttempt
        |> where([a], a.email_key == ^String.downcase(invitation.delivery_email))
        |> Repo.one!()

      assert attempt.delivery_email == invitation.delivery_email
      assert attempt.return_to == "/projects/invitations/#{invitation.id}/accept"
      refute attempt.return_to =~ "token"
    end
  end

  describe "identity transition" do
    test "fresh proof authenticates the invited identity without revoking other sessions" do
      %{invitation: invitation} = invited()

      other = SddOrchestrator.HostedAccessFixtures.verified_hosted_session_fixture()
      other_cookie = other.session_cookie.value

      assert {:ok, _access} = Sessions.authenticate(other_cookie)

      %{attempt: attempt, raw_token: raw_token} =
        SddOrchestrator.HostedAccessFixtures.magic_link_attempt_fixture(%{
          email: invitation.delivery_email,
          return_to: "/projects/invitations/#{invitation.id}/accept"
        })

      assert {:ok, result} = HostedAccess.verify_magic_link(attempt.id, raw_token, %{})
      assert result.return_to == "/projects/invitations/#{invitation.id}/accept"

      # This browser now holds the invited identity's credential.
      assert {:ok, invited_access} = Sessions.authenticate(result.session_cookie.value)
      assert InvitationProof.proof_state(invitation, invited_access.hosted_identity) == :proven

      # The other identity's server-side session is untouched.
      assert {:ok, other_access} = Sessions.authenticate(other_cookie)
      assert other_access.hosted_identity.id == other.hosted_identity.id
    end

    test "proof alone grants no project access" do
      %{project: project, invitation: invitation, invitee: invitee} = invited()

      assert InvitationProof.proof_state(invitation, invitee.hosted_identity) == :proven
      refute Participation.active_participant(project.id, invitee.hosted_identity.id)
      assert Participation.active_participants(project.id) == []
      assert {:error, :unauthorized} = Participation.owned_project(invitee.account.id, project.id)
      assert Repo.get!(ProjectInvitation, invitation.id).status == "pending"
    end
  end

  describe "open_for_identity/3" do
    test "resolves the return visit for the proven invitee only" do
      %{invitation: invitation, invitee: invitee} = invited()
      other = ParticipationFixtures.invited_identity_fixture()

      assert {:ok, opened} =
               InvitationProof.open_for_identity(invitation.id, invitee.hosted_identity)

      assert opened.invitation.id == invitation.id

      assert {:error, :invalid_or_expired} =
               InvitationProof.open_for_identity(invitation.id, other.hosted_identity)

      assert {:error, :invalid_or_expired} = InvitationProof.open_for_identity(invitation.id, nil)

      assert {:error, :invalid_or_expired} =
               InvitationProof.open_for_identity(Ecto.UUID.generate(), invitee.hosted_identity)
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
end
