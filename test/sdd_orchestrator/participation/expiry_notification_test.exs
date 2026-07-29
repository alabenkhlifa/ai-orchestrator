defmodule SddOrchestrator.Participation.ExpiryNotificationTest do
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Notifications
  alias SddOrchestrator.Notifications.AccountNotification
  alias SddOrchestrator.Participation.{Invitations, ProjectInvitation, ProjectNotifications}
  alias SddOrchestrator.ParticipationDeliveryDouble
  alias SddOrchestrator.ParticipationFixtures

  @address "invitee@example.com"

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

  describe "expiry projection" do
    test "notifies only the project owner with a minimized record" do
      %{project: project, account: account} = owned_project()
      invitee = ParticipationFixtures.invited_identity_fixture()
      address = invitee.external_identity.display_identifier

      {:ok, %{invitation: invitation}} = Invitations.create(project, account.id, address)
      now = expire(invitation)

      assert [notification] = Notifications.list(account.id)
      assert notification.event_type == "participation.invitation_expired"
      assert notification.subject_ref == invitation.id
      assert notification.event_version == invitation.credential_version
      assert notification.project_label == project.name
      assert notification.link_path == "/projects/#{project.id}/participation"
      assert notification.occurred_at == now
      assert AccountNotification.unread?(notification)
      assert Notifications.unread_count(account.id) == 1

      # The invited person receives no project notification.
      assert Notifications.list(invitee.account.id) == []
      assert Notifications.unread_count(invitee.account.id) == 0

      body = notification.title <> notification.body
      refute body =~ address
      refute body =~ invitation.id
      refute body =~ "token"
      assert body =~ project.name
    end

    test "creates one record per expiry sweep replay" do
      %{project: project, account: account} = owned_project()
      {:ok, %{invitation: invitation}} = Invitations.create(project, account.id, @address)
      now = expire(invitation)

      assert Invitations.expire_due(now) == 0
      expired = Repo.get!(ProjectInvitation, invitation.id)
      assert {:ok, _replayed} = ProjectNotifications.invitation_expired(project, expired)

      assert length(Notifications.list(account.id)) == 1
      assert Repo.aggregate(AccountNotification, :count) == 1
    end

    test "keeps unread state durable and mark-read idempotent for the owner" do
      %{project: project, account: account} = owned_project()
      %{account: other_account} = owned_project()
      {:ok, %{invitation: invitation}} = Invitations.create(project, account.id, @address)
      expire(invitation)

      [notification] = Notifications.list(account.id)

      assert {:error, :not_found} = Notifications.mark_read(other_account.id, notification.id)
      assert Notifications.unread_count(account.id) == 1

      assert {:ok, read} = Notifications.mark_read(account.id, notification.id)
      refute AccountNotification.unread?(read)
      assert {:ok, again} = Notifications.mark_read(account.id, notification.id)
      assert again.read_at == read.read_at
      assert Notifications.unread_count(account.id) == 0
    end

    test "sends no notification for a canceled or accepted invitation" do
      %{project: project, account: account} = owned_project()
      {:ok, %{invitation: canceled}} = Invitations.create(project, account.id, @address)
      {:ok, _canceled} = Invitations.cancel(project, account.id, @address)

      assert Invitations.expire_due(DateTime.add(canceled.expires_at, 60, :second)) == 0
      assert Notifications.list(account.id) == []
    end

    test "records one notification per expired invitation version" do
      %{project: project, account: account} = owned_project()
      {:ok, _created} = Invitations.create(project, account.id, @address)
      {:ok, %{invitation: replaced}} = Invitations.resend(project, account.id, @address)

      expire(replaced)

      assert [notification] = Notifications.list(account.id)
      assert notification.event_version == 2
    end
  end

  defp owned_project do
    result = ParticipationFixtures.hosted_project_fixture()

    ParticipationFixtures.member_profile_fixture(result.project, result.account, %{
      role: "owner",
      display_name: ParticipationFixtures.unique_display_name("Owner")
    })

    result
  end

  defp expire(invitation) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.update_all(
      from(i in ProjectInvitation, where: i.id == ^invitation.id),
      set: [expires_at: DateTime.add(now, -1, :second)]
    )

    assert Invitations.expire_due(now) == 1
    now
  end
end
