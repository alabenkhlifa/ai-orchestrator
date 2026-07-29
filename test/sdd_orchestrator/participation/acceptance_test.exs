defmodule SddOrchestrator.Participation.AcceptanceTest do
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Notifications
  alias SddOrchestrator.Participation

  alias SddOrchestrator.Participation.{
    Acceptance,
    InvitationProof,
    Invitations,
    ProjectInvitation,
    ProjectMemberProfile,
    ProjectParticipant
  }

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

  describe "accept/4" do
    test "creates exactly one participant, profile, and consumed invitation" do
      %{project: project, invitation: invitation, invitee: invitee} = invited()

      assert {:ok, accepted} =
               Acceptance.accept(invitation.id, invitee.hosted_identity, "  New Member  ")

      assert accepted.project.id == project.id
      assert accepted.participant.project_id == project.id
      assert accepted.participant.hosted_identity_id == invitee.hosted_identity.id
      assert accepted.participant.state == "active"
      assert accepted.profile.role == "participant"
      assert accepted.profile.display_name == "New Member"
      assert accepted.profile.account_id == invitee.account.id

      assert Participation.active_participant(project.id, invitee.hosted_identity.id).id ==
               accepted.participant.id

      consumed = Repo.get!(ProjectInvitation, invitation.id)
      assert consumed.status == "accepted"
      assert consumed.terminal_reason == "accepted"
      assert is_nil(consumed.token_digest)
      assert is_nil(consumed.token_salt)

      assert Repo.aggregate(ProjectParticipant, :count) == 1
      assert Repo.aggregate(ProjectMemberProfile, :count) == 2
    end

    test "notifies the new participant and the project owner" do
      %{project: project, account: owner_account, invitation: invitation, invitee: invitee} =
        invited()

      {:ok, accepted} =
        Acceptance.accept(invitation.id, invitee.hosted_identity, "New Member")

      assert [participant_notification] = Notifications.list(invitee.account.id)
      assert participant_notification.event_type == "participation.joined"
      assert participant_notification.subject_ref == accepted.profile.id
      assert participant_notification.link_path == "/projects/#{project.id}"

      assert [owner_notification] = Notifications.list(owner_account.id)
      assert owner_notification.event_type == "participation.participant_joined"
      assert owner_notification.actor_label == "New Member"
      assert owner_notification.link_path == "/projects/#{project.id}/participation"

      refute participant_notification.body =~ invitation.delivery_email
      refute owner_notification.body =~ invitation.delivery_email
    end

    test "returns the existing participation when the same invitation is replayed" do
      %{project: project, invitation: invitation, invitee: invitee} = invited()

      {:ok, first} = Acceptance.accept(invitation.id, invitee.hosted_identity, "New Member")
      assert {:ok, replayed} = Acceptance.accept(invitation.id, invitee.hosted_identity, "Other")

      assert replayed.participant.id == first.participant.id
      assert replayed.profile.id == first.profile.id
      assert replayed.profile.display_name == "New Member"
      assert Repo.aggregate(ProjectParticipant, :count) == 1
      assert length(Participation.active_participants(project.id)) == 1
      assert length(Notifications.list(invitee.account.id)) == 1
    end

    test "keeps one active participant when acceptance races itself" do
      %{project: project, invitation: invitation, invitee: invitee} = invited()

      results =
        1..4
        |> Enum.map(fn index ->
          Task.async(fn ->
            Repo.checkout(fn ->
              Acceptance.accept(invitation.id, invitee.hosted_identity, "Racer #{index}")
            end)
          end)
        end)
        |> Task.await_many(5_000)

      assert Enum.any?(results, &match?({:ok, _accepted}, &1))
      assert Repo.aggregate(ProjectParticipant, :count) == 1
      assert length(Participation.active_participants(project.id)) == 1
      assert Repo.get!(ProjectInvitation, invitation.id).status == "accepted"
    end
  end

  describe "safe failure" do
    test "creates no partial state for an unusable invitation" do
      %{account: account, project: project, invitation: invitation, invitee: invitee} = invited()

      assert {:error, :invalid_or_expired} =
               Acceptance.accept(Ecto.UUID.generate(), invitee.hosted_identity, "Name")

      assert {:error, :invalid_or_expired} =
               Acceptance.accept("not-an-id", invitee.hosted_identity, "Name")

      assert {:error, :invalid_or_expired} = Acceptance.accept(invitation.id, nil, "Name")

      past = DateTime.add(invitation.expires_at, 1, :second)

      assert {:error, :invalid_or_expired} =
               Acceptance.accept(invitation.id, invitee.hosted_identity, "Name", past)

      {:ok, _canceled} = Invitations.cancel(project, account.id, invitation.delivery_email)

      assert {:error, :invalid_or_expired} =
               Acceptance.accept(invitation.id, invitee.hosted_identity, "Name")

      assert Repo.aggregate(ProjectParticipant, :count) == 0
      assert Participation.active_participants(project.id) == []
      assert Notifications.list(account.id) == []
    end

    test "denies an identity that did not prove the invited address" do
      %{project: project, invitation: invitation} = invited()
      other = ParticipationFixtures.invited_identity_fixture()

      assert InvitationProof.proof_state(invitation, other.hosted_identity) == :different_email

      assert {:error, :invalid_or_expired} =
               Acceptance.accept(invitation.id, other.hosted_identity, "Impostor")

      assert Repo.aggregate(ProjectParticipant, :count) == 0
      refute Participation.active_participant(project.id, other.hosted_identity.id)
      assert Repo.get!(ProjectInvitation, invitation.id).status == "pending"
    end

    test "rolls back when the project display name is unavailable or invalid" do
      %{project: project, invitation: invitation, invitee: invitee} = invited()
      owner_profile = Participation.owner_profile(project.id)

      assert {:error, :display_name_taken} =
               Acceptance.accept(
                 invitation.id,
                 invitee.hosted_identity,
                 String.upcase(owner_profile.display_name)
               )

      assert {:error, :invalid_display_name} =
               Acceptance.accept(invitation.id, invitee.hosted_identity, "")

      assert {:error, :invalid_display_name} =
               Acceptance.accept(invitation.id, invitee.hosted_identity, "member@example.com")

      assert Repo.aggregate(ProjectParticipant, :count) == 0
      assert Repo.aggregate(ProjectMemberProfile, :count) == 1
      assert Repo.get!(ProjectInvitation, invitation.id).status == "pending"
      assert Notifications.list(invitee.account.id) == []
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

    assert_received {:participation_email, _email}

    Map.merge(result, %{invitation: invitation, invitee: invitee})
  end
end
