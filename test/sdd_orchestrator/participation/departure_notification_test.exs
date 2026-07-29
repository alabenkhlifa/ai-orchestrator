defmodule SddOrchestrator.Participation.DepartureNotificationTest do
  use SddOrchestrator.DataCase, async: true

  alias SddOrchestrator.Notifications
  alias SddOrchestrator.Notifications.AccountNotification
  alias SddOrchestrator.Participation
  alias SddOrchestrator.Participation.Revocations
  alias SddOrchestrator.ParticipationFixtures

  describe "removal" do
    test "reaches the removed person at their account boundary" do
      %{project: project, account: owner_account, identity: identity} = joined()

      {:ok, %{revocation: revocation}} =
        Revocations.remove(project, owner_account.id, identity.hosted_identity.id)

      assert [notification] = Notifications.list(identity.account.id)
      assert notification.event_type == "participation.removed"
      assert notification.subject_ref == revocation.id
      assert notification.event_version == revocation.contract_version
      assert notification.occurred_at == revocation.occurred_at
      assert AccountNotification.unread?(notification)

      # The link is account-level, not a project link, and restores no access.
      assert notification.link_path == "/hosted/access/sessions"
      refute notification.link_path =~ project.id
      refute Participation.active_participant(project.id, identity.hosted_identity.id)

      # The owner is not notified about their own action.
      assert Notifications.list(owner_account.id) == []
    end

    test "stays readable and markable after project access has ended" do
      %{project: project, account: owner_account, identity: identity} = joined()

      {:ok, _removed} = Revocations.remove(project, owner_account.id, identity.hosted_identity.id)

      assert {:error, :unauthorized} =
               Participation.visible_project(
                 project.id,
                 identity.account.id,
                 identity.hosted_identity.id
               )

      assert [notification] = Notifications.list(identity.account.id)
      assert {:ok, read} = Notifications.mark_read(identity.account.id, notification.id)
      assert {:ok, again} = Notifications.mark_read(identity.account.id, notification.id)
      assert again.read_at == read.read_at
      assert Notifications.unread_count(identity.account.id) == 0

      # Reading the notification did not restore anything.
      refute Participation.active_participant(project.id, identity.hosted_identity.id)
    end

    test "carries only the approved minimum context" do
      %{project: project, account: owner_account, identity: identity} = joined()

      {:ok, _removed} = Revocations.remove(project, owner_account.id, identity.hosted_identity.id)

      [notification] = Notifications.list(identity.account.id)
      content = notification.title <> notification.body

      assert content =~ project.name
      refute content =~ identity.external_identity.display_identifier
      refute content =~ "token"
      refute content =~ "invitation"
    end
  end

  describe "leave" do
    test "reaches the project owner only" do
      %{project: project, account: owner_account, identity: identity} = joined()

      {:ok, %{revocation: revocation}} =
        Revocations.leave(project, identity.account.id, identity.hosted_identity.id)

      assert [notification] = Notifications.list(owner_account.id)
      assert notification.event_type == "participation.left"
      assert notification.subject_ref == revocation.id
      assert notification.actor_label == "Member Label"
      assert notification.link_path == "/projects/#{project.id}/participation"

      # The person who left is not notified about their own action.
      assert Notifications.list(identity.account.id) == []
    end
  end

  describe "replay safety" do
    test "one departure creates one record per recipient" do
      %{project: project, account: owner_account, identity: identity} = joined()

      {:ok, %{revocation: revocation}} =
        Revocations.remove(project, owner_account.id, identity.hosted_identity.id)

      assert {:error, :not_a_participant} =
               Revocations.remove(project, owner_account.id, identity.hosted_identity.id)

      assert length(Notifications.list(identity.account.id)) == 1
      assert Repo.aggregate(AccountNotification, :count) == 1

      # Re-projecting the same handoff is idempotent through the shared key.
      assert {:ok, replayed} =
               Notifications.deliver(
                 SddOrchestrator.Participation.ProjectNotifications.removal_event(
                   project,
                   revocation
                 )
               )

      assert replayed.subject_ref == revocation.id
      assert Repo.aggregate(AccountNotification, :count) == 1
    end

    test "a rejoined and re-removed person receives a second, distinct record" do
      %{project: project, account: owner_account, identity: identity} = joined()

      {:ok, _first} = Revocations.remove(project, owner_account.id, identity.hosted_identity.id)
      ParticipationFixtures.participant_fixture(project, identity.hosted_identity)
      {:ok, _second} = Revocations.remove(project, owner_account.id, identity.hosted_identity.id)

      assert length(Notifications.list(identity.account.id)) == 2
    end
  end

  defp joined do
    result = ParticipationFixtures.hosted_project_fixture()

    ParticipationFixtures.member_profile_fixture(result.project, result.account, %{
      role: "owner",
      display_name: ParticipationFixtures.unique_display_name("Owner")
    })

    identity = ParticipationFixtures.invited_identity_fixture()
    ParticipationFixtures.participant_fixture(result.project, identity.hosted_identity)

    ParticipationFixtures.member_profile_fixture(result.project, identity.account, %{
      role: "participant",
      display_name: "Member Label"
    })

    Map.put(result, :identity, identity)
  end
end
