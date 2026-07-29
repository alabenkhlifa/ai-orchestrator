defmodule SddOrchestrator.Participation.InvitationResendTest do
  use SddOrchestrator.DataCase, async: false

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

  describe "resend/3" do
    test "replaces the credential and expiry without duplicating the invitation" do
      %{project: project, account: account} = owned_project()
      {:ok, %{invitation: original}} = Invitations.create(project, account.id, @address)
      original_token = received_token()

      Repo.update_all(
        from(i in ProjectInvitation, where: i.id == ^original.id),
        set: [
          expires_at:
            DateTime.utc_now() |> DateTime.add(60, :second) |> DateTime.truncate(:second)
        ]
      )

      assert {:ok, %{invitation: replaced, delivery: {:ok, delivery}}} =
               Invitations.resend(project, account.id, "INVITEE@example.com")

      assert replaced.id == original.id
      assert replaced.status == "pending"
      assert replaced.credential_version == 2
      assert replaced.token_digest != original.token_digest
      assert replaced.token_salt != original.token_salt
      assert Repo.aggregate(ProjectInvitation, :count) == 1

      seconds = DateTime.diff(replaced.expires_at, DateTime.utc_now())
      assert_in_delta seconds, 7 * 24 * 60 * 60, 5

      new_token = received_token()
      refute new_token == original_token
      assert replaced.token_digest == :crypto.hash(:sha256, replaced.token_salt <> new_token)

      # The prior link no longer matches the stored credential.
      refute replaced.token_digest == :crypto.hash(:sha256, replaced.token_salt <> original_token)
      assert delivery.status == "sent"
    end

    test "sends the replacement message and records its own delivery version" do
      %{project: project, account: account} = owned_project()
      {:ok, _created} = Invitations.create(project, account.id, @address)
      assert_received {:participation_email, first}

      {:ok, _resent} = Invitations.resend(project, account.id, @address)
      assert_received {:participation_email, second}

      assert first.subject =~ "You're invited"
      assert second.subject =~ "new invitation link"
      assert second.text_body =~ "Any earlier link no longer works."

      invitation = Invitations.pending_for(project.id, @address)
      assert Invitations.pending_for(project.id, @address).credential_version == 2

      assert %{status: "sent"} =
               SddOrchestrator.Participation.EmailDelivery.result(:invitation, invitation.id, 1)

      assert %{status: "sent"} =
               SddOrchestrator.Participation.EmailDelivery.result(
                 :invitation_resent,
                 invitation.id,
                 2
               )
    end

    test "rotates once per request so repeated resends keep one usable link" do
      %{project: project, account: account} = owned_project()
      {:ok, _created} = Invitations.create(project, account.id, @address)

      for expected_version <- 2..4 do
        assert {:ok, %{invitation: invitation}} =
                 Invitations.resend(project, account.id, @address)

        assert invitation.credential_version == expected_version
      end

      assert Repo.aggregate(ProjectInvitation, :count) == 1
      assert Invitations.pending_for(project.id, @address).credential_version == 4
    end

    test "requires a pending invitation" do
      %{project: project, account: account} = owned_project()

      assert {:error, :no_pending_invitation} =
               Invitations.resend(project, account.id, @address)

      assert Repo.aggregate(ProjectInvitation, :count) == 0
      refute_received {:participation_email, _email}
    end

    test "applies the same authorization and eligibility rules as creation" do
      %{project: project, account: account, owner: owner} = owned_project()
      %{account: other_account} = owned_project()
      {:ok, _created} = Invitations.create(project, account.id, @address)

      assert {:error, :unauthorized} = Invitations.resend(project, other_account.id, @address)
      assert {:error, :unauthorized} = Invitations.resend(project, nil, @address)
      assert {:error, :invalid_email} = Invitations.resend(project, account.id, "invitee")

      assert {:error, {:existing_role, :owner}} =
               Invitations.resend(project, account.id, owner.external_identity.display_identifier)

      assert Invitations.pending_for(project.id, @address).credential_version == 1
    end
  end

  describe "fresh re-invitation" do
    test "is allowed after a terminal invitation and starts a new credential" do
      %{project: project, account: account} = owned_project()
      {:ok, %{invitation: original}} = Invitations.create(project, account.id, @address)

      {:ok, _terminal} =
        original
        |> ProjectInvitation.terminal_changeset("declined", "declined")
        |> Repo.update()

      assert {:ok, %{invitation: fresh}} = Invitations.create(project, account.id, @address)

      assert fresh.id != original.id
      assert fresh.status == "pending"
      assert fresh.credential_version == 1
      assert Repo.aggregate(ProjectInvitation, :count) == 2
      assert Invitations.pending_for(project.id, @address).id == fresh.id
    end

    test "keeps at most one pending invitation per project and address" do
      %{project: project, account: account} = owned_project()
      {:ok, _created} = Invitations.create(project, account.id, @address)

      assert {:error, :invitation_already_pending} =
               Invitations.create(project, account.id, @address)

      assert Repo.aggregate(
               from(i in ProjectInvitation, where: i.status == "pending"),
               :count
             ) == 1
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

  defp received_token do
    assert_received {:participation_email, email}
    [_, token] = Regex.run(~r/token=([A-Za-z0-9_-]+)/, email.text_body)
    token
  end
end
