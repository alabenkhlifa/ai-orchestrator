defmodule SddOrchestrator.Participation.InvitationEmailTest do
  use SddOrchestrator.DataCase, async: false

  import ExUnit.CaptureLog

  alias SddOrchestrator.Participation.{
    EmailDelivery,
    Invitations,
    ParticipationEmail,
    ProjectInvitation
  }

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

  describe "credential selection" do
    test "each lifecycle message carries the credential current at its version" do
      %{project: project, account: account} = owned_project()

      {:ok, _created} = Invitations.create(project, account.id, @address)
      first_token = received_token()

      {:ok, %{invitation: replaced}} = Invitations.resend(project, account.id, @address)
      second_token = received_token()

      refute first_token == second_token

      assert replaced.token_digest ==
               :crypto.hash(:sha256, replaced.token_salt <> second_token)

      refute replaced.token_digest == :crypto.hash(:sha256, replaced.token_salt <> first_token)

      assert %{status: "sent", event_version: 1} =
               EmailDelivery.result(:invitation, replaced.id, 1)

      assert %{status: "sent", event_version: 2} =
               EmailDelivery.result(:invitation_resent, replaced.id, 2)
    end

    test "the cancellation message carries no link and no credential" do
      %{project: project, account: account} = owned_project()
      {:ok, %{invitation: invitation}} = Invitations.create(project, account.id, @address)
      invitation_token = received_token()

      {:ok, _canceled} = Invitations.cancel(project, account.id, @address)
      assert_received {:participation_email, cancellation}

      refute cancellation.text_body =~ "http"
      refute cancellation.text_body =~ "token="
      refute cancellation.text_body =~ invitation_token
      refute cancellation.text_body =~ invitation.id

      assert %{status: "sent"} =
               EmailDelivery.result(:invitation_canceled, invitation.id, 1)
    end
  end

  describe "minimized template context" do
    test "every lifecycle message names only the project, action, and its own link" do
      %{project: project, account: account} = owned_project()

      {:ok, %{invitation: invitation}} = Invitations.create(project, account.id, @address)
      assert_received {:participation_email, created}

      {:ok, _resent} = Invitations.resend(project, account.id, @address)
      assert_received {:participation_email, resent}

      {:ok, _canceled} = Invitations.cancel(project, account.id, @address)
      assert_received {:participation_email, canceled}

      owner_profile = SddOrchestrator.Participation.owner_profile(project.id)

      for email <- [created, resent, canceled] do
        body = String.downcase(email.text_body <> email.subject)

        assert body =~ String.downcase(project.name)

        for forbidden <- [
              "requirements",
              "specification",
              "evidence",
              "repository",
              "already has an account",
              String.downcase(owner_profile.display_name)
            ] do
          refute body =~ forbidden
        end

        refute email.text_body =~ invitation.email_digest |> Base.encode16(case: :lower)
      end
    end
  end

  describe "replay idempotency" do
    test "an already sent lifecycle message is not delivered twice" do
      %{project: project, account: account} = owned_project()
      {:ok, %{invitation: invitation}} = Invitations.create(project, account.id, @address)
      assert_received {:participation_email, _first}

      context = %{
        subject_ref: invitation.id,
        event_version: 1,
        recipient: @address,
        project_label: project.name,
        url: ParticipationEmail.invitation_url(invitation.id, "x")
      }

      assert {:ok, replayed} = EmailDelivery.deliver(:invitation, context)
      assert replayed.status == "sent"
      refute_received {:participation_email, _second}
      assert Repo.aggregate(SddOrchestrator.Participation.ParticipationEmailDelivery, :count) == 1
    end

    test "a failed message is retried in place and then settles" do
      %{project: project, account: account} = owned_project()
      ParticipationDeliveryDouble.fail_next()

      log =
        capture_log(fn ->
          {:ok, %{invitation: invitation, delivery: {:ok, failed}}} =
            Invitations.create(project, account.id, @address)

          assert failed.status == "failed"
          assert failed.failure_code == "delivery_failed"

          ParticipationDeliveryDouble.succeed()

          context = %{
            subject_ref: invitation.id,
            event_version: 1,
            recipient: @address,
            project_label: project.name,
            url: ParticipationEmail.invitation_url(invitation.id, "x")
          }

          assert {:ok, retried} = EmailDelivery.deliver(:invitation, context)
          assert retried.id == failed.id
          assert retried.status == "sent"
        end)

      assert log =~ "participation_email_delivery_failed"

      assert Repo.aggregate(SddOrchestrator.Participation.ParticipationEmailDelivery, :count) == 1
    end
  end

  describe "account-neutral delivery" do
    test "the outcome shape is identical for a known and an unknown address" do
      %{project: project, account: account} = owned_project()
      existing = ParticipationFixtures.invited_identity_fixture()

      {:ok, known} =
        Invitations.create(project, account.id, existing.external_identity.display_identifier)

      {:ok, unknown} = Invitations.create(project, account.id, "nobody@example.com")

      assert {:ok, known_delivery} = known.delivery
      assert {:ok, unknown_delivery} = unknown.delivery
      assert known_delivery.status == unknown_delivery.status
      assert known_delivery.failure_code == unknown_delivery.failure_code
      assert known_delivery.event_type == unknown_delivery.event_type
    end

    test "a provider failure keeps the invitation usable and recorded" do
      %{project: project, account: account} = owned_project()
      ParticipationDeliveryDouble.fail_next(:raise)

      capture_log(fn ->
        {:ok, %{invitation: invitation, delivery: {:ok, delivery}}} =
          Invitations.create(project, account.id, @address)

        assert delivery.status == "failed"
        assert delivery.failure_code == "provider_unavailable"
        assert Repo.get!(ProjectInvitation, invitation.id).status == "pending"
        assert Invitations.usable(invitation.id)
      end)
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
