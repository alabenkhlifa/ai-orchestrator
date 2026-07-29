defmodule SddOrchestrator.Participation.RemovalEmailTest do
  use SddOrchestrator.DataCase, async: false

  import ExUnit.CaptureLog

  alias SddOrchestrator.Participation
  alias SddOrchestrator.Participation.{EmailDelivery, ParticipationEmailDelivery, Revocations}
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

  describe "removal email" do
    test "reaches the address currently verified for that identity" do
      %{project: project, account: owner_account, identity: identity} = joined()

      {:ok, %{revocation: revocation}} =
        Revocations.remove(project, owner_account.id, identity.hosted_identity.id)

      assert_received {:participation_email, email}
      assert email.to == [{"", identity.external_identity.display_identifier}]
      assert email.subject =~ project.name
      assert email.subject =~ "no longer have access"

      delivery = EmailDelivery.result(:participant_removed, revocation.id, 1)
      assert delivery.status == "sent"
      assert delivery.recipient_address == identity.external_identity.display_identifier
      assert delivery.delivered_at
    end

    test "carries no credential, link, or project content" do
      %{project: project, account: owner_account, identity: identity} = joined()

      {:ok, _removed} = Revocations.remove(project, owner_account.id, identity.hosted_identity.id)

      assert_received {:participation_email, email}
      body = String.downcase(email.text_body)

      refute body =~ "http"
      refute body =~ "token"
      refute body =~ "invitation"

      for forbidden <- ["requirements", "specification", "evidence", "repository", "member label"] do
        refute body =~ forbidden
      end

      assert body =~ String.downcase(project.name)
      assert body =~ "your account is unchanged"
    end

    test "restores no access and is not repeated for the same departure" do
      %{project: project, account: owner_account, identity: identity} = joined()

      {:ok, %{revocation: revocation}} =
        Revocations.remove(project, owner_account.id, identity.hosted_identity.id)

      assert_received {:participation_email, _first}

      # A retried lifecycle action finds nothing to remove and sends nothing.
      assert {:error, :not_a_participant} =
               Revocations.remove(project, owner_account.id, identity.hosted_identity.id)

      refute_received {:participation_email, _second}

      # Re-issuing the same event returns the recorded outcome without resending.
      assert {:ok, replayed} =
               EmailDelivery.deliver(:participant_removed, %{
                 subject_ref: revocation.id,
                 event_version: revocation.contract_version,
                 recipient: identity.external_identity.display_identifier,
                 project_label: project.name
               })

      assert replayed.status == "sent"
      refute_received {:participation_email, _third}
      assert Repo.aggregate(ParticipationEmailDelivery, :count) == 1
      refute Participation.active_participant(project.id, identity.hosted_identity.id)
    end

    test "a provider failure keeps the removal committed and records a diagnostic" do
      %{project: project, account: owner_account, identity: identity} = joined()
      ParticipationDeliveryDouble.fail_next()

      log =
        capture_log(fn ->
          assert {:ok, %{revocation: revocation}} =
                   Revocations.remove(project, owner_account.id, identity.hosted_identity.id)

          delivery = EmailDelivery.result(:participant_removed, revocation.id, 1)
          assert delivery.status == "failed"
          assert delivery.failure_code == "delivery_failed"
          assert is_nil(delivery.delivered_at)
        end)

      assert log =~ "participation_email_delivery_failed"
      refute log =~ identity.external_identity.display_identifier

      # The authoritative removal is unaffected by the delivery outcome.
      refute Participation.active_participant(project.id, identity.hosted_identity.id)
      assert [_revocation] = Revocations.pending()
    end

    test "leaving sends no removal message" do
      %{project: project, identity: identity} = joined()

      {:ok, _left} = Revocations.leave(project, identity.account.id, identity.hosted_identity.id)

      refute_received {:participation_email, _email}
      assert Repo.aggregate(ParticipationEmailDelivery, :count) == 0
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
