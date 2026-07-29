defmodule SddOrchestrator.Participation.InvitationsTest do
  use SddOrchestrator.DataCase, async: false

  import ExUnit.CaptureLog

  alias SddOrchestrator.Accounts.{Account, HostedIdentity}
  alias SddOrchestrator.Participation
  alias SddOrchestrator.Participation.{EmailDigest, Invitations, ProjectInvitation}
  alias SddOrchestrator.ParticipationDeliveryDouble
  alias SddOrchestrator.ParticipationFixtures
  alias SddOrchestrator.Projects.Project

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

  describe "create/3" do
    test "creates one pending invitation and sends its link" do
      %{project: project, account: account} = owned_project()

      assert {:ok, %{invitation: invitation, delivery: {:ok, delivery}}} =
               Invitations.create(project, account.id, "  Invitee@Example.com ")

      assert invitation.project_id == project.id
      assert invitation.invited_by_account_id == account.id
      assert invitation.status == "pending"
      assert invitation.credential_version == 1
      assert invitation.delivery_email == "Invitee@Example.com"
      assert ProjectInvitation.pending?(invitation)

      seconds = DateTime.diff(invitation.expires_at, DateTime.utc_now())
      assert_in_delta seconds, 7 * 24 * 60 * 60, 5

      assert delivery.status == "sent"
      assert_received {:participation_email, email}
      assert email.to == [{"", "Invitee@Example.com"}]
      assert email.text_body =~ "/projects/invitations/accept?invitation=#{invitation.id}"
    end

    test "grants no project authorization before acceptance" do
      %{project: project, account: account} = owned_project()
      invitee = ParticipationFixtures.invited_identity_fixture()

      {:ok, _result} =
        Invitations.create(project, account.id, invitee.external_identity.display_identifier)

      refute Participation.active_participant(project.id, invitee.hosted_identity.id)
      assert Participation.active_participants(project.id) == []
      assert {:error, :unauthorized} = Participation.owned_project(invitee.account.id, project.id)
    end

    test "stores no raw credential and keeps the address protected" do
      %{project: project, account: account} = owned_project()

      {:ok, %{invitation: invitation}} =
        Invitations.create(project, account.id, "invitee@example.com")

      assert_received {:participation_email, email}
      [_, raw_token] = Regex.run(~r/token=([A-Za-z0-9_-]+)/, email.text_body)

      assert is_binary(invitation.token_digest)
      assert is_binary(invitation.token_salt)
      assert invitation.token_digest == :crypto.hash(:sha256, invitation.token_salt <> raw_token)
      refute inspect(invitation) =~ "invitee@example.com"
      refute inspect(invitation) =~ raw_token

      %{rows: [[stored_email, stored_digest]]} =
        Repo.query!(
          "SELECT delivery_email, email_digest FROM project_invitations WHERE id = $1",
          [Ecto.UUID.dump!(invitation.id)]
        )

      refute stored_email =~ "invitee@example.com"
      refute stored_digest =~ "invitee@example.com"
      assert {:ok, digest} = EmailDigest.compute("INVITEE@example.com")
      assert invitation.email_digest == digest
    end

    test "allows at most one pending invitation per project and address" do
      %{project: project, account: account} = owned_project()

      assert {:ok, _first} = Invitations.create(project, account.id, "invitee@example.com")

      assert {:error, :invitation_already_pending} =
               Invitations.create(project, account.id, "INVITEE@example.com")

      assert Repo.aggregate(ProjectInvitation, :count) == 1
      assert Invitations.pending_for(project.id, "invitee@example.com").project_id == project.id
    end

    test "scopes invitations to one project" do
      %{project: project, account: account} = owned_project()
      %{project: other_project, account: other_account} = owned_project()

      assert {:ok, _first} = Invitations.create(project, account.id, "invitee@example.com")

      assert {:ok, _second} =
               Invitations.create(other_project, other_account.id, "invitee@example.com")

      assert Repo.aggregate(ProjectInvitation, :count) == 2
      refute Invitations.pending_for(other_project.id, "someone-else@example.com")
    end

    test "rejects a non-owner without creating invitation state" do
      %{project: project} = owned_project()
      %{account: other_account} = owned_project()

      assert {:error, :unauthorized} =
               Invitations.create(project, other_account.id, "invitee@example.com")

      assert {:error, :unauthorized} = Invitations.create(project, nil, "invitee@example.com")

      assert {:error, :unauthorized} =
               Invitations.create(Ecto.UUID.generate(), other_account.id, "invitee@example.com")

      assert {:error, :unauthorized} =
               Invitations.create("not-a-project", other_account.id, "invitee@example.com")

      assert Repo.aggregate(ProjectInvitation, :count) == 0
      refute_received {:participation_email, _email}
    end

    test "keeps collaboration unavailable for a device-authoritative project" do
      %{account: account} = owned_project()

      device_project = %Project{
        id: Ecto.UUID.generate(),
        workspace_id: Ecto.UUID.generate(),
        storage_mode: "device"
      }

      assert {:error, :not_hosted_project} =
               Invitations.create(device_project, account.id, "invitee@example.com")

      assert Repo.aggregate(ProjectInvitation, :count) == 0
    end

    test "requires the owner display profile before the first invitation" do
      %{project: project, account: account} = ParticipationFixtures.hosted_project_fixture()

      assert {:error, :owner_profile_required} =
               Invitations.create(project, account.id, "invitee@example.com")

      assert Repo.aggregate(ProjectInvitation, :count) == 0
      refute_received {:participation_email, _email}
    end

    test "rejects an address that is not a usable email" do
      %{project: project, account: account} = owned_project()

      for invalid <- ["", "   ", "invitee", "in vitee@example.com", nil, 42] do
        assert {:error, :invalid_email} = Invitations.create(project, account.id, invalid)
      end

      assert Repo.aggregate(ProjectInvitation, :count) == 0
    end
  end

  describe "account neutrality" do
    test "an existing identity and an unknown address produce the same result shape" do
      %{project: project, account: account} = owned_project()
      existing = ParticipationFixtures.invited_identity_fixture()

      assert {:ok, known} =
               Invitations.create(
                 project,
                 account.id,
                 existing.external_identity.display_identifier
               )

      assert {:ok, unknown} = Invitations.create(project, account.id, "nobody@example.com")

      assert Map.keys(known) == Map.keys(unknown)
      assert known.invitation.status == unknown.invitation.status
      assert elem(known.delivery, 0) == elem(unknown.delivery, 0)
      assert elem(known.delivery, 1).status == elem(unknown.delivery, 1).status

      assert_received {:participation_email, first}
      assert_received {:participation_email, second}
      assert normalize_body(first.text_body) == normalize_body(second.text_body)
    end

    test "creation creates or resolves no account or identity" do
      %{project: project, account: account} = owned_project()
      before_accounts = Repo.aggregate(Account, :count)
      before_identities = Repo.aggregate(HostedIdentity, :count)

      {:ok, _result} = Invitations.create(project, account.id, "brand-new@example.com")

      assert Repo.aggregate(Account, :count) == before_accounts
      assert Repo.aggregate(HostedIdentity, :count) == before_identities
    end

    test "the structured log names the project and invitation but never the address" do
      %{project: project, account: account} = owned_project()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: :warning) end)

      log =
        capture_log(fn ->
          {:ok, _result} = Invitations.create(project, account.id, "invitee@example.com")
        end)

      assert log =~ "participation_invitation"
      assert log =~ "project_id=#{project.id}"
      assert log =~ "outcome=created"
      refute log =~ "invitee@example.com"
      refute log =~ "invitee"
    end
  end

  describe "delivery outcome" do
    test "keeps the pending invitation recoverable when the provider fails" do
      %{project: project, account: account} = owned_project()
      ParticipationDeliveryDouble.fail_next()

      log =
        capture_log(fn ->
          assert {:ok, %{invitation: invitation, delivery: {:ok, delivery}}} =
                   Invitations.create(project, account.id, "invitee@example.com")

          assert invitation.status == "pending"
          assert delivery.status == "failed"
        end)

      assert log =~ "participation_email_delivery_failed"
      assert Repo.aggregate(ProjectInvitation, :count) == 1
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

  # Removes the per-invitation identifiers so two messages can be compared for
  # identical wording regardless of which address they were sent to.
  defp normalize_body(body) do
    body
    |> String.replace(~r/invitation=[0-9a-f-]+/, "invitation=ID")
    |> String.replace(~r/token=[A-Za-z0-9_-]+/, "token=TOKEN")
  end
end
