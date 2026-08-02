defmodule SddOrchestrator.Participation.ReacceptanceTest do
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Notifications
  alias SddOrchestrator.Participation

  alias SddOrchestrator.Participation.{
    Acceptance,
    Invitations,
    ProjectInvitation,
    ProjectMemberProfile,
    ProjectParticipant,
    Revocations
  }

  alias SddOrchestrator.ParticipationDeliveryDouble
  alias SddOrchestrator.ParticipationFixtures
  alias SddOrchestrator.Privacy.Rights

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

  describe "accept/4 after departure" do
    test "removed participation requires a fresh proven invitation and reuses its profile" do
      context = joined() |> depart(:removed)
      historical_id = context.accepted.profile.id
      fresh = reinvite(context)
      unproven = ParticipationFixtures.invited_identity_fixture()

      refute Participation.active_participant(
               context.project.id,
               context.invitee.hosted_identity.id
             )

      assert Repo.get!(ProjectInvitation, fresh.id).status == "pending"

      assert {:error, :invalid_or_expired} =
               Acceptance.accept(fresh.id, unproven.hosted_identity, "Returned Member")

      assert Repo.get!(ProjectInvitation, fresh.id).status == "pending"

      assert {:ok, accepted} =
               Acceptance.accept(fresh.id, context.invitee.hosted_identity, " Returned Member ")

      assert accepted.participant.id != context.accepted.participant.id
      assert accepted.participant.state == "active"
      assert accepted.profile.id == historical_id
      assert accepted.profile.state == "active"
      assert accepted.profile.role == "participant"
      assert accepted.profile.display_name == "Returned Member"
      assert accepted.profile.account_id == context.invitee.account.id

      assert Repo.get!(ProjectInvitation, fresh.id).status == "accepted"
      assert one_active_participant?(context)

      assert Enum.any?(Notifications.list(context.invitee.account.id), fn notification ->
               notification.event_type == "participation.joined" and
                 notification.subject_ref == fresh.id and
                 notification.actor_label == "Returned Member"
             end)

      assert Enum.any?(Notifications.list(context.account.id), fn notification ->
               notification.event_type == "participation.participant_joined" and
                 notification.subject_ref == fresh.id and
                 notification.actor_label == "Returned Member"
             end)
    end

    test "self-leave reactivation preserves the linked profile identifier" do
      context = joined() |> depart(:left)
      historical_id = context.accepted.profile.id
      fresh = reinvite(context)

      assert {:ok, accepted} =
               Acceptance.accept(fresh.id, context.invitee.hosted_identity, "Back By Choice")

      assert accepted.profile.id == historical_id
      assert accepted.profile.state == "active"
      assert accepted.profile.display_name == "Back By Choice"
      assert accepted.participant.id != context.accepted.participant.id
      assert one_active_participant?(context)
    end

    test "creates a new profile only when no linked historical profile remains" do
      context = joined() |> depart(:left)
      historical_id = context.accepted.profile.id

      context.project.id
      |> Participation.member_profile(context.invitee.account.id)
      |> Repo.delete!()

      fresh = reinvite(context)

      assert {:ok, accepted} =
               Acceptance.accept(fresh.id, context.invitee.hosted_identity, "Fresh Profile")

      assert accepted.profile.id != historical_id
      assert accepted.profile.state == "active"
      assert accepted.profile.display_name == "Fresh Profile"
      refute Repo.get(ProjectMemberProfile, historical_id)
      assert one_active_participant?(context)
    end

    test "never relinks an anonymized profile and creates separate active presentation" do
      context = joined() |> depart(:removed)
      historical_id = context.accepted.profile.id

      assert {:ok, _anonymized} =
               Rights.anonymize_participation_attribution(
                 context.project.id,
                 context.invitee.account.id,
                 verified_request: true
               )

      anonymous_before = Repo.get!(ProjectMemberProfile, historical_id)
      assert anonymous_before.state == "anonymized"
      assert is_nil(anonymous_before.account_id)
      assert anonymous_before.display_name == ProjectMemberProfile.anonymous_label()

      fresh = reinvite(context)

      assert {:ok, accepted} =
               Acceptance.accept(fresh.id, context.invitee.hosted_identity, "A New Start")

      assert accepted.profile.id != historical_id
      assert accepted.profile.account_id == context.invitee.account.id
      assert accepted.profile.display_name == "A New Start"

      anonymous_after = Repo.get!(ProjectMemberProfile, historical_id)
      assert anonymous_after == anonymous_before
      assert one_active_participant?(context)
    end
  end

  describe "failure classification and atomicity" do
    test "keeps invalid and unavailable labels distinct and rolls every failure back" do
      context = joined() |> depart(:left)
      historical = Participation.member_profile(context.project.id, context.invitee.account.id)
      owner_profile = Participation.owner_profile(context.project.id)
      fresh = reinvite(context)
      before_invitee_notifications = Notifications.list(context.invitee.account.id)
      before_owner_notifications = Notifications.list(context.account.id)

      assert {:error, :display_name_taken} =
               Acceptance.accept(
                 fresh.id,
                 context.invitee.hosted_identity,
                 String.upcase(owner_profile.display_name)
               )

      assert {:error, :invalid_display_name} =
               Acceptance.accept(fresh.id, context.invitee.hosted_identity, "member@example.com")

      assert Repo.get!(ProjectInvitation, fresh.id).status == "pending"

      refute Participation.active_participant(
               context.project.id,
               context.invitee.hosted_identity.id
             )

      assert Repo.get!(ProjectMemberProfile, historical.id).state == "historical"
      assert Notifications.list(context.invitee.account.id) == before_invitee_notifications
      assert Notifications.list(context.account.id) == before_owner_notifications

      assert {:ok, accepted} =
               Acceptance.accept(fresh.id, context.invitee.hosted_identity, "Exact Label")

      assert accepted.profile.display_name == "Exact Label"
      refute accepted.profile.display_name =~ ~r/\d+$/
    end

    test "returns a typed identity-lifecycle conflict for an incompatible linked profile" do
      context = joined() |> depart(:left)
      historical = Participation.member_profile(context.project.id, context.invitee.account.id)

      historical
      |> Ecto.Changeset.change(role: "owner")
      |> Repo.update!()

      fresh = reinvite(context)
      before_notifications = all_notifications(context)

      assert {:error, :identity_lifecycle_conflict} =
               Acceptance.accept(fresh.id, context.invitee.hosted_identity, "Cannot Reactivate")

      assert Repo.get!(ProjectInvitation, fresh.id).status == "pending"
      assert Repo.get!(ProjectMemberProfile, historical.id).state == "historical"

      refute Participation.active_participant(
               context.project.id,
               context.invitee.hosted_identity.id
             )

      assert all_notifications(context) == before_notifications
    end

    test "returns a typed conflict when another authorization wins after invitation creation" do
      context = joined() |> depart(:removed)
      fresh = reinvite(context)

      winner =
        ParticipationFixtures.participant_fixture(
          context.project,
          context.invitee.hosted_identity
        )

      before_notifications = all_notifications(context)

      assert {:error, :identity_lifecycle_conflict} =
               Acceptance.accept(fresh.id, context.invitee.hosted_identity, "Losing Attempt")

      assert Repo.get!(ProjectInvitation, fresh.id).status == "pending"
      assert Repo.get!(ProjectParticipant, winner.id).state == "active"
      assert Repo.get!(ProjectMemberProfile, context.accepted.profile.id).state == "historical"
      assert all_notifications(context) == before_notifications
    end
  end

  describe "replay and concurrency" do
    test "replaying fresh re-acceptance returns the same new authorization and profile" do
      context = joined() |> depart(:left)
      fresh = reinvite(context)

      assert {:ok, first} =
               Acceptance.accept(fresh.id, context.invitee.hosted_identity, "Returned Once")

      assert {:ok, replayed} =
               Acceptance.accept(fresh.id, context.invitee.hosted_identity, "Ignored Replay")

      assert replayed.participant.id == first.participant.id
      assert replayed.profile.id == first.profile.id
      assert replayed.profile.display_name == "Returned Once"
      assert one_active_participant?(context)

      assert Enum.count(Notifications.list(context.invitee.account.id), fn notification ->
               notification.event_type == "participation.joined" and
                 notification.subject_ref == fresh.id
             end) == 1
    end

    test "concurrent fresh re-acceptance leaves one active authorization and one profile" do
      context = joined() |> depart(:left)
      historical_id = context.accepted.profile.id
      fresh = reinvite(context)

      results =
        1..4
        |> Enum.map(fn index ->
          Task.async(fn ->
            Repo.checkout(fn ->
              Acceptance.accept(
                fresh.id,
                context.invitee.hosted_identity,
                "Return Racer #{index}"
              )
            end)
          end)
        end)
        |> Task.await_many(5_000)

      successes = for {:ok, accepted} <- results, do: accepted
      assert successes != []

      assert Enum.all?(results, fn
               {:ok, _accepted} -> true
               {:error, :invalid_or_expired} -> true
               _other -> false
             end)

      assert successes |> Enum.map(& &1.participant.id) |> Enum.uniq() |> length() == 1
      assert successes |> Enum.map(& &1.profile.id) |> Enum.uniq() == [historical_id]
      assert one_active_participant?(context)
      assert Repo.aggregate(ProjectMemberProfile, :count) == 2
      assert Repo.get!(ProjectInvitation, fresh.id).status == "accepted"

      assert Enum.count(Notifications.list(context.invitee.account.id), fn notification ->
               notification.event_type == "participation.joined" and
                 notification.subject_ref == fresh.id
             end) == 1
    end
  end

  defp joined do
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

    {:ok, accepted} =
      Acceptance.accept(invitation.id, invitee.hosted_identity, "Original Member")

    Map.merge(result, %{accepted: accepted, invitation: invitation, invitee: invitee})
  end

  defp depart(context, :removed) do
    {:ok, departure} =
      Revocations.remove(
        context.project,
        context.account.id,
        context.invitee.hosted_identity.id
      )

    Map.put(context, :departure, departure)
  end

  defp depart(context, :left) do
    {:ok, departure} =
      Revocations.leave(
        context.project,
        context.invitee.account.id,
        context.invitee.hosted_identity.id
      )

    Map.put(context, :departure, departure)
  end

  defp reinvite(context) do
    {:ok, %{invitation: invitation}} =
      Invitations.create(
        context.project,
        context.account.id,
        context.invitee.external_identity.display_identifier
      )

    assert_received {:participation_email, _email}
    invitation
  end

  defp one_active_participant?(context) do
    case Participation.active_participants(context.project.id) do
      [%ProjectParticipant{hosted_identity_id: hosted_identity_id}] ->
        hosted_identity_id == context.invitee.hosted_identity.id

      _other ->
        false
    end
  end

  defp all_notifications(context) do
    %{
      invitee: Notifications.list(context.invitee.account.id),
      owner: Notifications.list(context.account.id)
    }
  end
end
