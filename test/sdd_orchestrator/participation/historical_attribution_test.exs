defmodule SddOrchestrator.Participation.HistoricalAttributionTest do
  @moduledoc """
  Proof that historical project attribution stops identifying a departed person
  once it may no longer do so.

  A departed member's last accepted label is kept only while project
  accountability still needs it. When that need ends, or a verified rights
  request overrides it, the label and the account link stop naming the person
  while the contribution history that attributes through the profile stays
  exactly where it was and grants no access back.
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

  describe "attribution_necessity/2" do
    test "a current member's label is their present name, not historical attribution" do
      context = joined()

      assert {:necessary, :active_participation} =
               Participation.attribution_necessity(
                 context.project.id,
                 context.identity.account.id
               )
    end

    test "a departed member stays identifiable while the handoff is unacknowledged" do
      context = departed(joined())

      refute ParticipationRevocation.acknowledged?(context.revocation)

      assert {:necessary, :pending_consumer_handoff} =
               Participation.attribution_necessity(
                 context.project.id,
                 context.identity.account.id
               )
    end

    test "identification stops being necessary once every handoff is acknowledged" do
      context = joined() |> departed() |> accountability_complete()

      assert {:unnecessary, :accountability_complete} =
               Participation.attribution_necessity(
                 context.project.id,
                 context.identity.account.id
               )
    end

    test "an account that never held attribution in the project has none" do
      context = joined()
      stranger = ParticipationFixtures.invited_identity_fixture()

      assert {:error, :not_found} =
               Participation.attribution_necessity(context.project.id, stranger.account.id)

      assert {:error, :not_found} =
               Participation.attribution_necessity(context.project.id, nil)
    end

    test "an already anonymized profile has nothing left to decide" do
      context = joined() |> departed() |> accountability_complete()

      {:ok, %{profile: anonymized}} =
        Participation.anonymize_member_attribution(
          context.project.id,
          context.identity.account.id
        )

      assert {:unnecessary, :already_anonymized} =
               Participation.attribution_necessity(anonymized)
    end
  end

  describe "assess_participation_attribution/2" do
    test "reports the necessity disposition and what the decision must propagate to" do
      context = departed(joined())

      assert {:ok, assessment} =
               Rights.assess_participation_attribution(
                 context.project.id,
                 context.identity.account.id
               )

      assert assessment.action == :anonymization
      assert assessment.project_id == context.project.id
      assert assessment.necessity == :necessary
      assert assessment.reason == :pending_consumer_handoff
      assert assessment.disposition == :identifiable_attribution_necessary

      propagation = assessment.propagation
      assert propagation.primary_store == :anonymized

      assert %{record: :participation_revocation, action: :anonymize} =
               Enum.find(propagation.derived_records, &(&1.record == :participation_revocation))

      # The copies this slice does not write are handed on rather than claimed.
      assert Enum.any?(propagation.pending_propagation, &(&1.record == :configured_processors))
      assert propagation.encrypted_backups.restore_scope == :approved_recovery_only
      assert propagation.encrypted_backups.deletion_propagation == :required
    end

    test "becomes available once accountability is complete" do
      context = joined() |> departed() |> accountability_complete()

      assert {:ok, %{necessity: :unnecessary, disposition: :anonymization_available}} =
               Rights.assess_participation_attribution(
                 context.project.id,
                 context.identity.account.id
               )
    end
  end

  describe "anonymize_participation_attribution/3" do
    test "refuses while attribution is still necessary and no verified request exists" do
      context = departed(joined())

      assert {:error, :attribution_necessary} =
               Rights.anonymize_participation_attribution(
                 context.project.id,
                 context.identity.account.id
               )

      profile = Participation.member_profile(context.project.id, context.identity.account.id)
      assert profile.state == "historical"
      assert profile.display_name == "Member Label"
      assert profile.account_id == context.identity.account.id
    end

    test "a verified rights request overrides a still-necessary label" do
      context = departed(joined())

      assert {:ok, result} =
               Rights.anonymize_participation_attribution(
                 context.project.id,
                 context.identity.account.id,
                 verified_request: true
               )

      assert result.basis == :verified_rights_request
      assert result.anonymous_label == @anonymous
      refute Participation.member_profile(context.project.id, context.identity.account.id)
    end

    test "a lapsed necessity is enough on its own" do
      context = joined() |> departed() |> accountability_complete()

      assert {:ok, %{basis: :attribution_no_longer_necessary}} =
               Rights.anonymize_participation_attribution(
                 context.project.id,
                 context.identity.account.id
               )
    end

    test "a current participant is refused on either path" do
      context = joined()

      assert {:error, :active_participation} =
               Rights.anonymize_participation_attribution(
                 context.project.id,
                 context.identity.account.id
               )

      assert {:error, :active_participation} =
               Rights.anonymize_participation_attribution(
                 context.project.id,
                 context.identity.account.id,
                 verified_request: true
               )

      assert {:error, :active_participation} =
               Participation.anonymize_member_attribution(
                 context.project.id,
                 context.identity.account.id
               )

      profile = Participation.member_profile(context.project.id, context.identity.account.id)
      assert profile.state == "active"
      assert profile.display_name == "Member Label"
    end

    test "an account with no attribution in the project is not found" do
      context = joined()
      stranger = ParticipationFixtures.invited_identity_fixture()

      assert {:error, :not_found} =
               Rights.anonymize_participation_attribution(
                 context.project.id,
                 stranger.account.id,
                 verified_request: true
               )
    end

    test "removes the account link and replaces the label with the anonymous one" do
      context = joined() |> departed() |> accountability_complete()

      assert {:ok, _result} =
               Rights.anonymize_participation_attribution(
                 context.project.id,
                 context.identity.account.id
               )

      profile = Repo.get(ProjectMemberProfile, profile_id(context))

      assert profile.state == "anonymized"
      assert is_nil(profile.account_id)
      assert profile.display_name == @anonymous
      assert profile.display_name_key == "former participant"
      assert profile.anonymized_at

      # The account can no longer reach the attribution, because nothing links
      # the two any more. That absence is the removal.
      refute Participation.member_profile(context.project.id, context.identity.account.id)
    end

    test "keeps the contribution history stable and referentially whole" do
      context = joined() |> departed() |> accountability_complete()

      before_profile =
        Participation.member_profile(context.project.id, context.identity.account.id)

      participant_id = context.revocation.project_participant_id
      before_count = Repo.aggregate(ProjectMemberProfile, :count)

      assert {:ok, _result} =
               Rights.anonymize_participation_attribution(
                 context.project.id,
                 context.identity.account.id
               )

      profile = Repo.get(ProjectMemberProfile, before_profile.id)

      # The row a contribution attributes through is the same row: same
      # identifier, same project, same role. Only the identifying part changed.
      assert profile.id == before_profile.id
      assert profile.project_id == before_profile.project_id
      assert profile.role == before_profile.role

      # Anonymization rewrites a row; it never adds or drops one.
      assert Repo.aggregate(ProjectMemberProfile, :count) == before_count

      # The departure record and the participation row it points at both survive.
      revocation = Repo.get(ParticipationRevocation, context.revocation.id)
      assert revocation.project_participant_id == participant_id
      assert revocation.contract_version == context.revocation.contract_version
      assert revocation.occurred_at == context.revocation.occurred_at
      assert revocation.reason == "removed"
      assert Repo.get(ProjectParticipant, participant_id)
    end

    test "anonymizes this specification's own derived copy of the label" do
      context = joined() |> departed() |> accountability_complete()
      assert context.revocation.last_display_name == "Member Label"
      assert context.revocation.former_account_id == context.identity.account.id

      assert {:ok, %{derived_revocations: 1}} =
               Rights.anonymize_participation_attribution(
                 context.project.id,
                 context.identity.account.id
               )

      revocation = Repo.get(ParticipationRevocation, context.revocation.id)

      assert revocation.last_display_name == @anonymous
      assert is_nil(revocation.former_account_id)
      assert is_nil(revocation.former_hosted_identity_id)
    end

    test "restores no project access" do
      context = joined() |> departed() |> accountability_complete()

      actor = %{
        account_id: context.identity.account.id,
        hosted_identity_id: context.identity.hosted_identity.id
      }

      assert {:ok, _result} =
               Rights.anonymize_participation_attribution(
                 context.project.id,
                 context.identity.account.id
               )

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

      # The anonymous label never rejoins the membership the owner manages.
      labels =
        context.project
        |> Participation.members(:owner, context.account.id)
        |> Enum.map(& &1.display_name)

      refute @anonymous in labels
      refute "Member Label" in labels
    end

    test "leaves the same person's attribution in another project untouched" do
      context = joined() |> departed() |> accountability_complete()
      other = ParticipationFixtures.hosted_project_fixture()
      ParticipationFixtures.participant_fixture(other.project, context.identity.hosted_identity)

      ParticipationFixtures.member_profile_fixture(other.project, context.identity.account, %{
        role: "participant",
        display_name: "Elsewhere"
      })

      assert {:ok, _result} =
               Rights.anonymize_participation_attribution(
                 context.project.id,
                 context.identity.account.id
               )

      elsewhere = Participation.member_profile(other.project.id, context.identity.account.id)
      assert elsewhere.state == "active"
      assert elsewhere.display_name == "Elsewhere"
      assert elsewhere.account_id == context.identity.account.id
    end

    test "cannot be repeated through an account link that no longer exists" do
      context = joined() |> departed() |> accountability_complete()
      before_count = Repo.aggregate(ProjectMemberProfile, :count)

      assert {:ok, _first} =
               Rights.anonymize_participation_attribution(
                 context.project.id,
                 context.identity.account.id
               )

      assert {:error, :not_found} =
               Rights.anonymize_participation_attribution(
                 context.project.id,
                 context.identity.account.id,
                 verified_request: true
               )

      assert Repo.aggregate(ProjectMemberProfile, :count) == before_count
    end
  end

  describe "project deletion" do
    test "sweeps every departed label the project still identifies" do
      context = departed(joined())

      ParticipationFixtures.member_profile_fixture(context.project, context.account, %{
        role: "owner",
        display_name: "Owner Label"
      })

      second = join_into(context.project, "Second Label")

      {:ok, _departed} =
        Revocations.leave(context.project, second.account.id, second.hosted_identity.id)

      untouched = ParticipationFixtures.hosted_project_fixture()
      elsewhere = join_into(untouched.project, "Untouched")

      assert {:ok, result} =
               Rights.anonymize_project_participation_attribution(context.project.id)

      assert result.basis == :project_deletion
      assert result.profiles == 2
      assert result.derived_revocations == 2

      refute Participation.member_profile(context.project.id, context.identity.account.id)
      refute Participation.member_profile(context.project.id, second.account.id)

      for revocation <- Repo.all(ParticipationRevocation) do
        assert revocation.last_display_name == @anonymous
        assert is_nil(revocation.former_account_id)
        assert is_nil(revocation.former_hosted_identity_id)
      end

      # The owner's own active label and another project are not swept.
      owner_profile = Participation.owner_profile(context.project.id)
      assert owner_profile.state == "active"

      still_there = Participation.member_profile(untouched.project.id, elsewhere.account.id)
      assert still_there.display_name == "Untouched"
    end

    test "deleting the project removes the attribution outright" do
      context = joined() |> departed() |> accountability_complete()

      # This is what hosted project deletion does; the cascade is the contract.
      assert {:ok, _deleted} = Repo.delete(context.project)

      assert Repo.aggregate(ProjectMemberProfile, :count) == 0
      assert Repo.aggregate(ParticipationRevocation, :count) == 0
      assert Repo.aggregate(ProjectParticipant, :count) == 0
    end
  end

  defp joined do
    result = ParticipationFixtures.hosted_project_fixture()
    identity = join_into(result.project, "Member Label")
    Map.put(result, :identity, identity)
  end

  defp join_into(project, display_name) do
    identity = ParticipationFixtures.invited_identity_fixture()
    ParticipationFixtures.participant_fixture(project, identity.hosted_identity)

    ParticipationFixtures.member_profile_fixture(project, identity.account, %{
      role: "participant",
      display_name: display_name
    })

    identity
  end

  # Departure runs through the real owner-removal boundary, so the profile
  # becomes historical and the durable handoff is published exactly as
  # production publishes it.
  defp departed(context) do
    {:ok, %{revocation: revocation}} =
      Revocations.remove(
        context.project,
        context.account.id,
        context.identity.hosted_identity.id
      )

    Map.put(context, :revocation, revocation)
  end

  defp accountability_complete(context) do
    {:ok, acknowledged} = Revocations.acknowledge(context.revocation.id, "delivery")
    Map.put(context, :revocation, acknowledged)
  end

  defp profile_id(context) do
    ProjectMemberProfile
    |> where([p], p.project_id == ^context.project.id and p.role == "participant")
    |> Repo.one!()
    |> Map.fetch!(:id)
  end
end
