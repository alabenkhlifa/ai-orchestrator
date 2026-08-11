defmodule SddOrchestrator.Participation.IdentityLifecycleCompatibilityTest do
  @moduledoc """
  Compatibility proof for specs/25 (Task 4).

  Tasks 1-3 each repaired one boundary of the participation identity
  lifecycle: fresh re-acceptance after departure reactivates a linked
  historical profile, acknowledgement and the 30-day retention rule clear a
  handoff's former-identity links, and verified rights anonymization
  correlates its derived revocation through the stable
  `project_participant_id` rather than the transient `former_account_id`.
  This file does not re-derive those units' own exhaustive coverage; it proves
  the three repairs compose together and do not regress the adjacent
  contracts Slice 07/08 already shipped: current-participant authorization,
  the revocation consumer, and notification minimization.
  """
  use SddOrchestrator.DataCase, async: true

  import Swoosh.TestAssertions

  alias SddOrchestrator.Delivery.{Feature, RevocationConsumer}
  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.Notifications
  alias SddOrchestrator.Participation

  alias SddOrchestrator.Participation.{
    Acceptance,
    Invitations,
    ParticipationRevocation,
    ProjectInvitation,
    ProjectMemberProfile,
    ProjectParticipant,
    Revocations
  }

  alias SddOrchestrator.ParticipationFixtures
  alias SddOrchestrator.Privacy.Rights

  @approved_verified [verified_request: true, approved: true]

  describe "full round trip and stable references" do
    test "a profile id and each revocation's participant link stay stable across two departures and a reacceptance" do
      context = joined_project()
      identity = ParticipationFixtures.invited_identity_fixture()

      {:ok, first} = invite_and_accept(context, identity, "First Term")
      profile_id = first.profile.id
      first_participant_id = first.participant.id

      {:ok, %{revocation: first_revocation}} =
        Revocations.leave(context.project, identity.account.id, identity.hosted_identity.id)

      assert first_revocation.project_participant_id == first_participant_id

      {:ok, second} = invite_and_accept(context, identity, "Second Term")

      # Reactivation reuses the same profile identifier and opens a fresh
      # participant row for the new join period.
      assert second.profile.id == profile_id
      assert second.participant.id != first_participant_id

      {:ok, %{revocation: second_revocation}} =
        Revocations.leave(context.project, identity.account.id, identity.hosted_identity.id)

      assert second_revocation.project_participant_id == second.participant.id
      assert second_revocation.project_participant_id != first_revocation.project_participant_id

      participant_ids =
        ProjectParticipant
        |> Repo.all()
        |> Enum.filter(&(&1.hosted_identity_id == identity.hosted_identity.id))
        |> Enum.map(& &1.id)
        |> Enum.sort()

      assert participant_ids == Enum.sort([first_participant_id, second.participant.id])

      # Acknowledging the second handoff must not disturb the first, still
      # pending, handoff from the earlier departure.
      assert {:ok, acknowledged} =
               Revocations.acknowledge(second_revocation.id, "compat-consumer")

      assert is_nil(acknowledged.former_account_id)
      assert is_nil(acknowledged.former_hosted_identity_id)

      untouched_first = Repo.get!(ParticipationRevocation, first_revocation.id)
      assert untouched_first.former_account_id == identity.account.id
      assert is_nil(untouched_first.acknowledged_at)

      # The closing verified anonymization must reach both handoffs through
      # their stable project_participant_id, not through the acknowledged
      # handoff's now-cleared former_account_id.
      assert {:ok, result} =
               Rights.anonymize_verified_participation(
                 context.project.id,
                 identity.account.id,
                 identity.hosted_identity.id,
                 @approved_verified
               )

      assert result.departure == :already_ended
      assert result.derived_revocations == 2

      final_first = Repo.get!(ParticipationRevocation, first_revocation.id)
      final_second = Repo.get!(ParticipationRevocation, second_revocation.id)

      assert final_first.project_participant_id == first_participant_id
      assert final_second.project_participant_id == second.participant.id
      assert final_first.last_display_name == ProjectMemberProfile.anonymous_label()
      assert final_second.last_display_name == ProjectMemberProfile.anonymous_label()

      profile = Repo.get!(ProjectMemberProfile, profile_id)
      assert profile.state == "anonymized"
      assert is_nil(profile.account_id)
    end
  end

  describe "current-participant authorization" do
    test "an unrelated active participant's authorization is unaffected by another account's reacceptance or anonymization" do
      context = joined_project()
      bystander = ParticipationFixtures.invited_identity_fixture()
      {:ok, _} = invite_and_accept(context, bystander, "Bystander")

      mover = ParticipationFixtures.invited_identity_fixture()
      {:ok, _} = invite_and_accept(context, mover, "Mover")

      leaver = ParticipationFixtures.invited_identity_fixture()
      {:ok, _} = invite_and_accept(context, leaver, "Leaver")

      assert {:ok, :participant} =
               Participation.member_role(
                 context.project,
                 bystander.account.id,
                 bystander.hosted_identity.id
               )

      # A different account's fresh re-acceptance elsewhere in the project.
      {:ok, _} = Revocations.leave(context.project, mover.account.id, mover.hosted_identity.id)
      {:ok, _} = invite_and_accept(context, mover, "Mover Returns")

      # A different account's verified anonymization elsewhere in the project.
      assert {:ok, _result} =
               Rights.anonymize_verified_participation(
                 context.project.id,
                 leaver.account.id,
                 leaver.hosted_identity.id,
                 @approved_verified
               )

      assert {:ok, :participant} =
               Participation.member_role(
                 context.project,
                 bystander.account.id,
                 bystander.hosted_identity.id
               )

      assert Participation.active_participant(context.project.id, bystander.hosted_identity.id)
    end
  end

  describe "invitation atomicity" do
    test "a re-acceptance rolled back by an unavailable display name leaves no partial participant, profile, or invitation state" do
      context = joined_project()
      identity = ParticipationFixtures.invited_identity_fixture()
      {:ok, first} = invite_and_accept(context, identity, "First Term")

      {:ok, _} =
        Revocations.leave(context.project, identity.account.id, identity.hosted_identity.id)

      fresh = reinvite(context, identity)
      owner_profile = Participation.owner_profile(context.project.id)

      assert {:error, :display_name_taken} =
               Acceptance.accept(
                 fresh.id,
                 identity.hosted_identity,
                 String.upcase(owner_profile.display_name)
               )

      refute Participation.active_participant(context.project.id, identity.hosted_identity.id)
      assert Repo.get!(ProjectInvitation, fresh.id).status == "pending"
      assert Repo.get!(ProjectMemberProfile, first.profile.id).state == "historical"

      # The invitation stays usable: the rollback was total, not partial.
      assert {:ok, accepted} =
               Acceptance.accept(fresh.id, identity.hosted_identity, "Retry Works")

      assert accepted.profile.id == first.profile.id
    end
  end

  describe "acknowledgement cleanup" do
    test "acknowledging one departure's handoff is unaffected by a concurrent reacceptance elsewhere in the project" do
      context = joined_project()

      target = ParticipationFixtures.invited_identity_fixture()
      {:ok, _} = invite_and_accept(context, target, "Target")

      {:ok, %{revocation: revocation}} =
        Revocations.remove(context.project, context.account.id, target.hosted_identity.id)

      other = ParticipationFixtures.invited_identity_fixture()
      {:ok, _} = invite_and_accept(context, other, "Other")
      {:ok, _} = Revocations.leave(context.project, other.account.id, other.hosted_identity.id)
      {:ok, _} = invite_and_accept(context, other, "Other Returns")

      assert {:ok, first_ack} = Revocations.acknowledge(revocation.id, "compat-consumer")
      assert is_nil(first_ack.former_account_id)
      assert is_nil(first_ack.former_hosted_identity_id)
      assert first_ack.reason == "removed"
      assert first_ack.acknowledged_at

      # Idempotent replay leaves the stable handoff fields intact.
      assert {:ok, second_ack} = Revocations.acknowledge(revocation.id, "compat-consumer")
      assert second_ack.acknowledged_at == first_ack.acknowledged_at
      assert second_ack.reason == first_ack.reason
      assert second_ack.project_participant_id == first_ack.project_participant_id

      assert Participation.active_participant(context.project.id, other.hosted_identity.id)
    end
  end

  describe "rights anonymization" do
    test "verified anonymization still anonymizes a derived revocation whose identity links acknowledgement already cleared" do
      context = joined_project()
      identity = ParticipationFixtures.invited_identity_fixture()
      {:ok, accepted} = invite_and_accept(context, identity, "Departing Member")

      {:ok, %{revocation: revocation}} =
        Revocations.leave(context.project, identity.account.id, identity.hosted_identity.id)

      assert {:ok, acknowledged} = Revocations.acknowledge(revocation.id, "compat-consumer")
      assert is_nil(acknowledged.former_account_id)
      assert is_nil(acknowledged.former_hosted_identity_id)

      assert {:ok, result} =
               Rights.anonymize_verified_participation(
                 context.project.id,
                 identity.account.id,
                 identity.hosted_identity.id,
                 @approved_verified
               )

      assert result.departure == :already_ended
      assert result.derived_revocations == 1

      final = Repo.get!(ParticipationRevocation, revocation.id)
      assert final.last_display_name == ProjectMemberProfile.anonymous_label()
      assert is_nil(final.former_account_id)
      assert is_nil(final.former_hosted_identity_id)
      assert final.acknowledged_at == acknowledged.acknowledged_at

      profile = Repo.get!(ProjectMemberProfile, accepted.profile.id)
      assert profile.state == "anonymized"
      assert is_nil(profile.account_id)
    end
  end

  describe "Slice 07 revocation consumer" do
    test "applies a fresh reacceptance's later removal exactly as an ordinary one" do
      delivery = DeliveryFixtures.delivery_project_fixture()
      identity = delivery.identity

      {:ok, _} =
        Revocations.leave(delivery.project, identity.account.id, identity.hosted_identity.id)

      # Drains the first departure's own handoff (nothing was assigned yet) so
      # the pass below claims exactly the handoff this test is about.
      assert {:ok, _} = RevocationConsumer.claim_and_apply(delivery.workspace)

      {:ok, %{invitation: invitation}} =
        Invitations.create(
          delivery.project,
          delivery.account.id,
          identity.external_identity.display_identifier
        )

      assert {:ok, _reaccepted} =
               Acceptance.accept(invitation.id, identity.hosted_identity, "Returned Contributor")

      held =
        DeliveryFixtures.feature_fixture(delivery.project, identity.account, %{
          assigned_account_id: identity.account.id
        })

      {:ok, %{revocation: revocation}} =
        Revocations.remove(delivery.project, delivery.account.id, identity.hosted_identity.id)

      assert {:ok, [applied]} = RevocationConsumer.claim_and_apply(delivery.workspace)
      assert applied.revocation_id == revocation.id
      assert applied.former_account_id == identity.account.id
      assert applied.cleared_feature_ids == [held.id]

      cleared = Repo.get!(Feature, held.id)
      assert is_nil(cleared.assigned_account_id)

      acknowledged = Repo.get!(ParticipationRevocation, revocation.id)
      assert acknowledged.acknowledged_at
      assert is_nil(acknowledged.former_account_id)
    end

    test "applies a fresh reacceptance's later self-leave exactly as a removal is applied" do
      delivery = DeliveryFixtures.delivery_project_fixture()
      identity = delivery.identity

      {:ok, _} =
        Revocations.leave(delivery.project, identity.account.id, identity.hosted_identity.id)

      # Drains the first departure's own handoff (nothing was assigned yet) so
      # the pass below claims exactly the handoff this test is about.
      assert {:ok, _} = RevocationConsumer.claim_and_apply(delivery.workspace)

      {:ok, %{invitation: invitation}} =
        Invitations.create(
          delivery.project,
          delivery.account.id,
          identity.external_identity.display_identifier
        )

      assert {:ok, _reaccepted} =
               Acceptance.accept(invitation.id, identity.hosted_identity, "Returned Again")

      held =
        DeliveryFixtures.feature_fixture(delivery.project, identity.account, %{
          assigned_account_id: identity.account.id
        })

      {:ok, %{revocation: revocation}} =
        Revocations.leave(delivery.project, identity.account.id, identity.hosted_identity.id)

      assert {:ok, [applied]} = RevocationConsumer.claim_and_apply(delivery.workspace)
      assert applied.revocation_id == revocation.id
      assert applied.cleared_feature_ids == [held.id]
      assert is_nil(Repo.get!(Feature, held.id).assigned_account_id)
    end
  end

  describe "notification minimization" do
    test "acceptance and removal notifications after a full round trip stay singular, targeted, and minimized" do
      context = joined_project()
      identity = ParticipationFixtures.invited_identity_fixture()

      {:ok, _first} = invite_and_accept(context, identity, "Round Tripper")

      {:ok, _} =
        Revocations.leave(context.project, identity.account.id, identity.hosted_identity.id)

      {:ok, _second} = invite_and_accept(context, identity, "Round Tripper Returns")

      joined_events =
        Enum.filter(
          Notifications.list(identity.account.id),
          &(&1.event_type == "participation.joined")
        )

      assert length(joined_events) == 2

      # The two invitation emails already sent above are not the departure this
      # test asserts on.
      drain_emails()

      assert {:ok, %{revocation: revocation}} =
               Revocations.remove(
                 context.project,
                 context.account.id,
                 identity.hosted_identity.id
               )

      assert [removed_notification] =
               Enum.filter(
                 Notifications.list(identity.account.id),
                 &(&1.event_type == "participation.removed")
               )

      assert removed_notification.subject_ref == revocation.id
      content = removed_notification.title <> removed_notification.body
      refute content =~ identity.external_identity.display_identifier

      assert_email_sent(fn email ->
        assert email.to == [{"", identity.external_identity.display_identifier}]
        assert email.subject =~ "no longer have access"
        body = String.downcase(email.text_body)
        refute body =~ "token"
        refute body =~ "invitation"
        true
      end)
    end
  end

  describe "fail-closed" do
    test "an unverified or unapproved anonymization request changes nothing" do
      context = joined_project()
      identity = ParticipationFixtures.invited_identity_fixture()
      {:ok, _} = invite_and_accept(context, identity, "Guarded Member")

      assert {:error, :unverified_request} =
               Rights.anonymize_verified_participation(
                 context.project.id,
                 identity.account.id,
                 identity.hosted_identity.id,
                 []
               )

      assert {:error, :unverified_request} =
               Rights.anonymize_verified_participation(
                 context.project.id,
                 identity.account.id,
                 identity.hosted_identity.id,
                 approved: true
               )

      assert Participation.active_participant(context.project.id, identity.hosted_identity.id)
    end

    test "the immutable owner still cannot leave" do
      context = joined_project()

      assert {:error, :owner_cannot_leave} =
               Revocations.leave(
                 context.project,
                 context.account.id,
                 context.owner.hosted_identity.id
               )
    end
  end

  describe "project isolation" do
    test "one account's reacceptance, revocation, and anonymization in one project never touch its profile or revocations in another" do
      context_a = joined_project()
      context_b = joined_project()
      identity = ParticipationFixtures.invited_identity_fixture()

      {:ok, _accept_a} = invite_and_accept(context_a, identity, "In Project A")
      {:ok, accept_b} = invite_and_accept(context_b, identity, "In Project B")

      {:ok, _} =
        Revocations.leave(context_a.project, identity.account.id, identity.hosted_identity.id)

      {:ok, _} = invite_and_accept(context_a, identity, "Back In A")

      assert {:ok, result} =
               Rights.anonymize_verified_participation(
                 context_a.project.id,
                 identity.account.id,
                 identity.hosted_identity.id,
                 @approved_verified
               )

      assert result.derived_revocations >= 1

      # Project B never saw a departure or anonymization for this account.
      assert Participation.active_participant(context_b.project.id, identity.hosted_identity.id)
      profile_b = Repo.get!(ProjectMemberProfile, accept_b.profile.id)
      assert profile_b.state == "active"
      assert profile_b.display_name == "In Project B"
      refute Repo.get_by(ParticipationRevocation, project_id: context_b.project.id)
    end
  end

  defp joined_project(attrs \\ %{}) do
    result = ParticipationFixtures.hosted_project_fixture(attrs)

    ParticipationFixtures.member_profile_fixture(result.project, result.account, %{
      role: "owner",
      display_name: ParticipationFixtures.unique_display_name("Owner")
    })

    result
  end

  defp invite_and_accept(context, identity, display_name) do
    fresh = reinvite(context, identity)
    Acceptance.accept(fresh.id, identity.hosted_identity, display_name)
  end

  defp reinvite(context, identity) do
    {:ok, %{invitation: invitation}} =
      Invitations.create(
        context.project,
        context.account.id,
        identity.external_identity.display_identifier
      )

    invitation
  end

  defp drain_emails do
    receive do
      {:email, _email} -> drain_emails()
    after
      0 -> :ok
    end
  end
end
