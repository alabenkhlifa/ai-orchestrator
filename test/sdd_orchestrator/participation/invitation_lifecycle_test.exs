defmodule SddOrchestrator.Participation.InvitationLifecycleTest do
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Participation
  alias SddOrchestrator.Participation.{Invitations, ProjectInvitation}
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

  describe "cancel/3" do
    test "ends the invitation and erases its credential immediately" do
      %{project: project, account: account} = owned_project()
      {:ok, %{invitation: invitation}} = Invitations.create(project, account.id, @address)

      assert {:ok, canceled} = Invitations.cancel(project, account.id, "INVITEE@example.com")

      assert canceled.id == invitation.id
      assert canceled.status == "canceled"
      assert canceled.terminal_reason == "canceled"
      assert canceled.terminal_at
      assert is_nil(canceled.token_digest)
      assert is_nil(canceled.token_salt)
      refute ProjectInvitation.pending?(canceled)
      refute Invitations.pending_for(project.id, @address)
      refute Invitations.usable(canceled.id)
    end

    test "notifies the invitee once and stays idempotent when repeated" do
      %{project: project, account: account} = owned_project()
      {:ok, _created} = Invitations.create(project, account.id, @address)
      assert_received {:participation_email, _invitation_email}

      assert {:ok, first} = Invitations.cancel(project, account.id, @address)
      assert_received {:participation_email, cancellation}
      assert cancellation.subject =~ "was canceled"

      assert {:ok, second} = Invitations.cancel(project, account.id, @address)
      assert second.id == first.id
      assert second.terminal_at == first.terminal_at
      refute_received {:participation_email, _second_cancellation}
    end

    test "creates no access and requires a fresh flow afterwards" do
      %{project: project, account: account} = owned_project()
      invitee = ParticipationFixtures.invited_identity_fixture()
      address = invitee.external_identity.display_identifier

      {:ok, _created} = Invitations.create(project, account.id, address)
      {:ok, canceled} = Invitations.cancel(project, account.id, address)

      refute Participation.active_participant(project.id, invitee.hosted_identity.id)
      assert Participation.active_participants(project.id) == []

      assert {:error, :no_pending_invitation} = Invitations.resend(project, account.id, address)

      assert {:ok, %{invitation: fresh}} = Invitations.create(project, account.id, address)
      assert fresh.id != canceled.id
      assert fresh.credential_version == 1
      assert fresh.status == "pending"
    end

    test "rejects a non-owner and an invitation that cannot be canceled" do
      %{project: project, account: account} = owned_project()
      %{account: other_account} = owned_project()
      {:ok, %{invitation: invitation}} = Invitations.create(project, account.id, @address)

      assert {:error, :unauthorized} = Invitations.cancel(project, other_account.id, @address)

      assert {:error, :no_pending_invitation} =
               Invitations.cancel(project, account.id, "other@example.com")

      {:ok, _accepted} =
        invitation
        |> ProjectInvitation.terminal_changeset("accepted", "accepted")
        |> Repo.update()

      assert {:error, :not_cancelable} = Invitations.cancel(project, account.id, @address)
    end
  end

  describe "expire_due/1" do
    test "ends only invitations past their seven-day lifetime" do
      %{project: project, account: account} = owned_project()
      {:ok, %{invitation: due}} = Invitations.create(project, account.id, @address)
      {:ok, %{invitation: fresh}} = Invitations.create(project, account.id, "later@example.com")

      now = DateTime.utc_now() |> DateTime.truncate(:second)
      set_expiry(due, DateTime.add(now, -1, :second))

      assert Invitations.expire_due(now) == 1

      expired = Repo.get!(ProjectInvitation, due.id)
      assert expired.status == "expired"
      assert expired.terminal_reason == "expired"
      assert expired.terminal_at == now
      assert is_nil(expired.token_digest)
      assert is_nil(expired.token_salt)
      refute Invitations.usable(expired.id)

      assert Repo.get!(ProjectInvitation, fresh.id).status == "pending"
      assert Invitations.usable(fresh.id)
    end

    test "is idempotent and changes no participant state" do
      %{project: project, account: account} = owned_project()
      invitee = ParticipationFixtures.invited_identity_fixture()
      participant = ParticipationFixtures.participant_fixture(project, invitee.hosted_identity)
      {:ok, %{invitation: due}} = Invitations.create(project, account.id, @address)

      now = DateTime.utc_now() |> DateTime.truncate(:second)
      set_expiry(due, DateTime.add(now, -60, :second))

      assert Invitations.expire_due(now) == 1
      assert Invitations.expire_due(now) == 0
      assert Invitations.expire_due(DateTime.add(now, 3600, :second)) == 0

      assert Participation.active_participant(project.id, invitee.hosted_identity.id).id ==
               participant.id
    end

    test "allows a fresh invitation after expiry" do
      %{project: project, account: account} = owned_project()
      {:ok, %{invitation: due}} = Invitations.create(project, account.id, @address)

      now = DateTime.utc_now() |> DateTime.truncate(:second)
      set_expiry(due, DateTime.add(now, -1, :second))
      assert Invitations.expire_due(now) == 1

      assert {:ok, %{invitation: fresh}} = Invitations.create(project, account.id, @address)
      assert fresh.id != due.id
      assert fresh.status == "pending"
      assert Repo.aggregate(ProjectInvitation, :count) == 2
    end
  end

  describe "usable/2" do
    test "refuses an expired, terminal, unknown, or malformed invitation" do
      %{project: project, account: account} = owned_project()
      {:ok, %{invitation: invitation}} = Invitations.create(project, account.id, @address)

      assert Invitations.usable(invitation.id)

      past = DateTime.add(invitation.expires_at, 1, :second)
      refute Invitations.usable(invitation.id, past)

      {:ok, _canceled} =
        invitation
        |> ProjectInvitation.terminal_changeset("canceled", "canceled")
        |> Repo.update()

      refute Invitations.usable(invitation.id)
      refute Invitations.usable(Ecto.UUID.generate())
      refute Invitations.usable("not-an-id")
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

  defp set_expiry(invitation, expires_at) do
    Repo.update_all(
      from(i in ProjectInvitation, where: i.id == ^invitation.id),
      set: [expires_at: expires_at]
    )
  end
end
