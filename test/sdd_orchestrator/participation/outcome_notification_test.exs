defmodule SddOrchestrator.Participation.OutcomeNotificationTest do
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Notifications
  alias SddOrchestrator.Notifications.AccountNotification
  alias SddOrchestrator.Participation
  alias SddOrchestrator.Participation.{Acceptance, Invitations}
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

  describe "acceptance recipients" do
    test "confirms to the participant and reports to the owner, and to nobody else" do
      %{project: project, account: owner_account, invitation: invitation, invitee: invitee} =
        invited()

      bystander = ParticipationFixtures.invited_identity_fixture()

      {:ok, accepted} = Acceptance.accept(invitation.id, invitee.hosted_identity, "New Member")

      assert [participant_event] = Notifications.list(invitee.account.id)
      assert participant_event.event_type == "participation.joined"
      assert participant_event.account_id == invitee.account.id
      assert participant_event.subject_ref == accepted.profile.id
      assert participant_event.link_path == "/projects/#{project.id}"
      assert AccountNotification.unread?(participant_event)

      assert [owner_event] = Notifications.list(owner_account.id)
      assert owner_event.event_type == "participation.participant_joined"
      assert owner_event.account_id == owner_account.id
      assert owner_event.link_path == "/projects/#{project.id}/participation"

      assert Notifications.list(bystander.account.id) == []
    end

    test "carries only the approved minimum context" do
      %{project: project, account: owner_account, invitation: invitation, invitee: invitee} =
        invited()

      {:ok, _accepted} = Acceptance.accept(invitation.id, invitee.hosted_identity, "New Member")

      owner_profile = Participation.owner_profile(project.id)
      [participant_event] = Notifications.list(invitee.account.id)
      [owner_event] = Notifications.list(owner_account.id)

      for event <- [participant_event, owner_event] do
        content = event.title <> event.body <> (event.project_label || "")

        assert content =~ project.name
        refute content =~ invitation.delivery_email
        refute content =~ invitation.id
        refute content =~ "token"
        refute content =~ "account"
        assert String.starts_with?(event.link_path, "/projects/#{project.id}")
      end

      assert owner_event.actor_label == "New Member"
      refute owner_event.body =~ owner_profile.display_name
    end

    test "creates one record per person even when the outcome is replayed" do
      %{account: owner_account, invitation: invitation, invitee: invitee} = invited()

      {:ok, _first} = Acceptance.accept(invitation.id, invitee.hosted_identity, "New Member")
      {:ok, _replayed} = Acceptance.accept(invitation.id, invitee.hosted_identity, "New Member")

      assert length(Notifications.list(invitee.account.id)) == 1
      assert length(Notifications.list(owner_account.id)) == 1
      assert Repo.aggregate(AccountNotification, :count) == 2
    end

    test "keeps unread delivery durable and mark-read authorized per recipient" do
      %{account: owner_account, invitation: invitation, invitee: invitee} = invited()

      {:ok, _accepted} = Acceptance.accept(invitation.id, invitee.hosted_identity, "New Member")

      [participant_event] = Notifications.list(invitee.account.id)

      assert {:error, :not_found} =
               Notifications.mark_read(owner_account.id, participant_event.id)

      assert Notifications.unread_count(invitee.account.id) == 1

      assert {:ok, read} = Notifications.mark_read(invitee.account.id, participant_event.id)
      assert {:ok, again} = Notifications.mark_read(invitee.account.id, participant_event.id)
      assert again.read_at == read.read_at
      assert Notifications.unread_count(invitee.account.id) == 0
      assert Notifications.unread_count(owner_account.id) == 1
    end
  end

  describe "decline recipients" do
    test "reports the outcome to the owner only" do
      %{project: project, account: owner_account, invitation: invitation, invitee: invitee} =
        invited()

      {:ok, declined} = Acceptance.decline(invitation.id, invitee.hosted_identity)

      assert [owner_event] = Notifications.list(owner_account.id)
      assert owner_event.event_type == "participation.invitation_declined"
      assert owner_event.subject_ref == invitation.id
      assert owner_event.event_version == invitation.credential_version
      assert owner_event.occurred_at == declined.terminal_at
      assert owner_event.link_path == "/projects/#{project.id}/participation"

      # The person who declined is not notified about a project they did not join.
      assert Notifications.list(invitee.account.id) == []

      content = owner_event.title <> owner_event.body
      refute content =~ invitation.delivery_email
      refute content =~ "account"
    end

    test "creates no acceptance record and no second decline record" do
      %{account: owner_account, invitation: invitation, invitee: invitee} = invited()

      {:ok, _declined} = Acceptance.decline(invitation.id, invitee.hosted_identity)

      assert {:error, :invalid_or_expired} =
               Acceptance.decline(invitation.id, invitee.hosted_identity)

      assert length(Notifications.list(owner_account.id)) == 1

      assert Enum.all?(
               Notifications.list(owner_account.id),
               &(&1.event_type == "participation.invitation_declined")
             )
    end
  end

  defp invited do
    result = ParticipationFixtures.hosted_project_fixture()

    ParticipationFixtures.member_profile_fixture(result.project, result.account, %{
      role: "owner",
      display_name: ParticipationFixtures.unique_display_name("Owner")
    })

    invitee = ParticipationFixtures.invited_identity_fixture()

    {:ok, %{invitation: invitation}} =
      Invitations.create(
        result.project,
        result.account.id,
        invitee.external_identity.display_identifier
      )

    assert_received {:participation_email, _email}

    Map.merge(result, %{invitation: invitation, invitee: invitee})
  end
end
