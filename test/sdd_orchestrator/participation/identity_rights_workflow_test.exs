defmodule SddOrchestrator.Participation.IdentityRightsWorkflowTest do
  @moduledoc """
  Proof of the ordered verified participant-anonymization workflow.

  An approved verified request from a current participant is served by first
  committing the authoritative self-departure and only then anonymizing the
  historical attribution departure leaves behind. Access never comes back, the
  departure is never rolled back, and nothing that survives — the stable
  contribution history, the anonymized handoff — identifies the person or
  derives a label from their email or another stable identifier.
  """
  use SddOrchestrator.DataCase, async: true

  alias SddOrchestrator.Participation

  alias SddOrchestrator.Participation.{
    Capabilities,
    ParticipationRevocation,
    ProjectMemberProfile,
    ProjectParticipant,
    Revocations
  }

  alias SddOrchestrator.ParticipationFixtures
  alias SddOrchestrator.Privacy.Rights

  @anonymous "Former participant"
  @approved_verified [verified_request: true, approved: true]

  describe "request disposition" do
    test "an unverified request is refused before anything changes" do
      context = joined()

      assert {:error, :unverified_request} = anonymize(context, [])
      assert {:error, :unverified_request} = anonymize(context, approved: true)

      assert Participation.active_participant(
               context.project.id,
               context.identity.hosted_identity.id
             )

      profile = Participation.member_profile(context.project.id, context.identity.account.id)
      assert profile.state == "active"
      assert Repo.aggregate(ParticipationRevocation, :count) == 0
    end

    test "identity verification alone is not the legal disposition" do
      context = joined()

      assert {:error, :approval_required} = anonymize(context, verified_request: true)

      assert Participation.active_participant(
               context.project.id,
               context.identity.hosted_identity.id
             )

      assert Repo.aggregate(ParticipationRevocation, :count) == 0
    end

    test "unverified processing continues to respect pending-handoff necessity" do
      context = departed(joined())

      refute ParticipationRevocation.acknowledged?(context.revocation)

      assert {:error, :attribution_necessary} =
               Rights.anonymize_participation_attribution(
                 context.project.id,
                 context.identity.account.id
               )

      assert {:error, :unverified_request} = anonymize(context, [])

      profile = Participation.member_profile(context.project.id, context.identity.account.id)
      assert profile.state == "historical"
      assert profile.display_name == "Member Label"
    end
  end

  describe "verified identity scope" do
    test "cannot end another participant's membership through a wrong identity" do
      context = joined()
      other = ParticipationFixtures.invited_identity_fixture()
      ParticipationFixtures.participant_fixture(context.project, other.hosted_identity)

      ParticipationFixtures.member_profile_fixture(context.project, other.account, %{
        role: "participant",
        display_name: "Other Label"
      })

      assert {:error, :not_found} =
               Rights.anonymize_verified_participation(
                 context.project.id,
                 context.identity.account.id,
                 other.hosted_identity.id,
                 @approved_verified
               )

      assert Participation.active_participant(context.project.id, other.hosted_identity.id)

      assert Participation.active_participant(
               context.project.id,
               context.identity.hosted_identity.id
             )

      assert Repo.aggregate(ParticipationRevocation, :count) == 0
    end

    test "an unknown, malformed, or absent identity fails closed" do
      context = joined()

      for hosted_identity_id <- [Ecto.UUID.generate(), "not-a-uuid", nil] do
        assert {:error, :not_found} =
                 Rights.anonymize_verified_participation(
                   context.project.id,
                   context.identity.account.id,
                   hosted_identity_id,
                   @approved_verified
                 )
      end

      assert {:error, :not_found} =
               Rights.anonymize_verified_participation(
                 context.project.id,
                 nil,
                 context.identity.hosted_identity.id,
                 @approved_verified
               )

      assert Participation.active_participant(
               context.project.id,
               context.identity.hosted_identity.id
             )
    end

    test "a project the requester never participated in is not found" do
      context = joined()
      elsewhere = ParticipationFixtures.hosted_project_fixture()

      assert {:error, :not_found} =
               Rights.anonymize_verified_participation(
                 elsewhere.project.id,
                 context.identity.account.id,
                 context.identity.hosted_identity.id,
                 @approved_verified
               )

      # The refusal in the wrong project ends nothing in the right one.
      assert Participation.active_participant(
               context.project.id,
               context.identity.hosted_identity.id
             )

      assert Repo.aggregate(ParticipationRevocation, :count) == 0
    end

    test "the immutable owner is refused" do
      context = joined()

      assert {:error, :owner_cannot_leave} =
               Rights.anonymize_verified_participation(
                 context.project.id,
                 context.account.id,
                 context.owner.hosted_identity.id,
                 @approved_verified
               )

      assert {:ok, %{account_id: owner_account_id}} = Participation.owner(context.project)
      assert owner_account_id == context.account.id
      assert Repo.aggregate(ParticipationRevocation, :count) == 0
    end
  end

  describe "current participant" do
    test "commits the authoritative departure first and anonymizes only after it" do
      context = joined()

      assert {:ok, result} = anonymize(context)

      assert result.workflow == :verified_participation_anonymization
      assert result.status == :complete
      assert result.participation == :ended
      assert result.departure == :committed
      assert result.basis == :verified_rights_request
      assert result.anonymous_label == @anonymous
      assert result.derived_revocations == 1

      # Departure went through the authoritative self-leave transition.
      participant = Repo.get(ProjectParticipant, context.participant.id)
      refute participant.state == "active"
      assert participant.departure_reason == "left"
      assert participant.departed_at

      # The durable handoff was published by the departure and then anonymized
      # by the later step: it exists, and it no longer names the person. That
      # order is the only way this record can look like this.
      assert [revocation] = Repo.all(ParticipationRevocation)
      assert revocation.reason == "left"
      assert revocation.project_participant_id == context.participant.id
      assert revocation.last_display_name == @anonymous
      assert is_nil(revocation.former_account_id)
      assert is_nil(revocation.former_hosted_identity_id)

      profile = Repo.get(ProjectMemberProfile, context.profile.id)
      assert profile.state == "anonymized"
      assert is_nil(profile.account_id)
      assert profile.display_name == @anonymous
    end

    test "access stays ended when anonymization must be retried" do
      # A participant whose presentation profile is absent leaves the workflow
      # nothing to anonymize after departure: the departure itself must stand.
      result = ParticipationFixtures.hosted_project_fixture()
      identity = ParticipationFixtures.invited_identity_fixture()
      ParticipationFixtures.participant_fixture(result.project, identity.hosted_identity)

      assert {:error, incomplete} =
               Rights.anonymize_verified_participation(
                 result.project.id,
                 identity.account.id,
                 identity.hosted_identity.id,
                 @approved_verified
               )

      assert incomplete.workflow == :verified_participation_anonymization
      assert incomplete.status == :retryable_incomplete
      assert incomplete.participation == :ended
      assert incomplete.departure == :committed
      assert incomplete.retry == :anonymization
      assert incomplete.reason == :not_found

      # The departure was not rolled back and no access came back with the
      # failure: the handoff exists and authorization stays fail-closed.
      assert Repo.aggregate(ParticipationRevocation, :count) == 1
      refute Participation.active_participant(result.project.id, identity.hosted_identity.id)

      assert {:error, :unauthorized} =
               Participation.member_role(
                 result.project,
                 identity.account.id,
                 identity.hosted_identity.id
               )
    end

    test "a retry after departure completes only the remaining anonymization" do
      # The departure step of a previous attempt committed; anonymization did
      # not. The retry must finish the anonymization without a second
      # departure and without touching the committed one.
      context = departed(joined())
      departed_participant = Repo.get(ProjectParticipant, context.participant.id)

      assert {:ok, result} = anonymize(context)

      assert result.status == :complete
      assert result.departure == :already_ended
      assert result.participation == :ended

      assert [revocation] = Repo.all(ParticipationRevocation)
      assert revocation.id == context.revocation.id

      retried = Repo.get(ProjectParticipant, context.participant.id)
      assert retried.state == departed_participant.state
      assert retried.departed_at == departed_participant.departed_at

      profile = Repo.get(ProjectMemberProfile, context.profile.id)
      assert profile.state == "anonymized"
    end
  end

  describe "departed requester" do
    test "an approved verified request overrides pending-handoff necessity" do
      context = departed(joined())

      refute ParticipationRevocation.acknowledged?(context.revocation)

      assert {:ok, result} = anonymize(context)

      assert result.status == :complete
      assert result.departure == :already_ended
      assert result.basis == :verified_rights_request
      assert result.derived_revocations == 1

      # The handoff stays available to its consumer, unacknowledged and
      # non-identifying: the override anonymized it rather than consuming it.
      revocation = Repo.get(ParticipationRevocation, context.revocation.id)
      assert is_nil(revocation.acknowledged_at)
      assert revocation.last_display_name == @anonymous
      assert is_nil(revocation.former_account_id)
      assert is_nil(revocation.former_hosted_identity_id)
    end

    test "preserves stable history without identifying links" do
      context = departed(joined())
      before_count = Repo.aggregate(ProjectMemberProfile, :count)

      assert {:ok, _result} = anonymize(context)

      profile = Repo.get(ProjectMemberProfile, context.profile.id)
      assert profile.id == context.profile.id
      assert profile.project_id == context.profile.project_id
      assert profile.role == context.profile.role
      assert Repo.aggregate(ProjectMemberProfile, :count) == before_count

      revocation = Repo.get(ParticipationRevocation, context.revocation.id)
      assert revocation.project_participant_id == context.participant.id
      assert revocation.contract_version == context.revocation.contract_version
      assert revocation.occurred_at == context.revocation.occurred_at
      assert revocation.reason == "left"
      assert Repo.get(ProjectParticipant, context.participant.id)
    end

    test "never derives the anonymous label from the email or another stable identifier" do
      context = joined(email: "Linkable.Person@example.com")

      assert {:ok, result} = anonymize(context)
      assert result.anonymous_label == @anonymous

      profile = Repo.get(ProjectMemberProfile, context.profile.id)
      assert profile.display_name == @anonymous
      assert profile.display_name_key == "former participant"

      revocation = Repo.one!(ParticipationRevocation)
      dump = inspect({profile, revocation})

      refute dump =~ "Linkable"
      refute dump =~ "linkable.person"
      refute dump =~ "Member Label"
      refute dump =~ context.identity.account.id
      refute dump =~ context.identity.hosted_identity.id
    end

    test "restores no project access" do
      context = departed(joined())

      actor = %{
        account_id: context.identity.account.id,
        hosted_identity_id: context.identity.hosted_identity.id
      }

      assert {:ok, _result} = anonymize(context)

      refute Participation.active_participant(
               context.project.id,
               context.identity.hosted_identity.id
             )

      assert {:error, :unauthorized} =
               Participation.member_role(
                 context.project,
                 context.identity.account.id,
                 context.identity.hosted_identity.id
               )

      assert {:error, :unauthorized} =
               Participation.visible_project(
                 context.project.id,
                 context.identity.account.id,
                 context.identity.hosted_identity.id
               )

      assert Capabilities.capabilities(context.project, actor) == []

      labels =
        context.project
        |> Participation.members(:owner, context.account.id)
        |> Enum.map(& &1.display_name)

      refute @anonymous in labels
      refute "Member Label" in labels
    end
  end

  defp joined(attrs \\ []) do
    result = ParticipationFixtures.hosted_project_fixture()
    identity = ParticipationFixtures.invited_identity_fixture(Map.new(attrs))

    participant =
      ParticipationFixtures.participant_fixture(result.project, identity.hosted_identity)

    profile =
      ParticipationFixtures.member_profile_fixture(result.project, identity.account, %{
        role: "participant",
        display_name: "Member Label"
      })

    result
    |> Map.put(:identity, identity)
    |> Map.put(:participant, participant)
    |> Map.put(:profile, profile)
  end

  # The precondition of the departed cases is the same authoritative
  # self-departure the workflow itself commits for a current participant.
  defp departed(context) do
    {:ok, %{revocation: revocation}} =
      Revocations.leave(
        context.project,
        context.identity.account.id,
        context.identity.hosted_identity.id
      )

    Map.put(context, :revocation, revocation)
  end

  defp anonymize(context, opts \\ @approved_verified) do
    Rights.anonymize_verified_participation(
      context.project.id,
      context.identity.account.id,
      context.identity.hosted_identity.id,
      opts
    )
  end
end
