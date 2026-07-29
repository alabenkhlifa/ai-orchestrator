defmodule SddOrchestrator.Participation.MemberProfileTest do
  use SddOrchestrator.DataCase, async: true

  alias SddOrchestrator.Participation
  alias SddOrchestrator.Participation.ProjectMemberProfile
  alias SddOrchestrator.ParticipationFixtures

  describe "rename_member_profile/4" do
    test "a participant renames only their own label and keeps their identity" do
      %{project: project, participant: participant, profile: profile, identity: identity} =
        project_with_participant()

      assert {:ok, renamed} =
               Participation.rename_member_profile(
                 project,
                 identity.account.id,
                 identity.hosted_identity.id,
                 "  Renamed Member  "
               )

      assert renamed.id == profile.id
      assert renamed.display_name == "Renamed Member"
      assert renamed.display_name_key == "renamed member"
      assert renamed.account_id == identity.account.id
      assert renamed.role == "participant"

      # Authorization identity is untouched by a presentation change.
      current = Participation.active_participant(project.id, identity.hosted_identity.id)
      assert current.id == participant.id
      assert current.hosted_identity_id == identity.hosted_identity.id
    end

    test "the owner renames their own label through the same action" do
      %{project: project, account: account} = project_with_participant()

      assert {:ok, renamed} =
               Participation.rename_member_profile(project, account.id, nil, "Owner Renamed")

      assert renamed.role == "owner"
      assert renamed.display_name == "Owner Renamed"
      assert Participation.owner_profile(project.id).display_name == "Owner Renamed"
    end

    test "rejects a conflicting label without an automatic suffix" do
      %{project: project, identity: identity} = project_with_participant()
      owner_profile = Participation.owner_profile(project.id)

      assert {:error, changeset} =
               Participation.rename_member_profile(
                 project,
                 identity.account.id,
                 identity.hosted_identity.id,
                 String.upcase(owner_profile.display_name)
               )

      assert "is already used in this project" in errors_on(changeset).display_name

      assert Participation.member_profile(project.id, identity.account.id).display_name ==
               "Member Label"
    end

    test "rejects an unusable label" do
      %{project: project, identity: identity} = project_with_participant()

      for invalid <- ["", "   ", "member@example.com", String.duplicate("n", 81)] do
        assert {:error, %Ecto.Changeset{}} =
                 Participation.rename_member_profile(
                   project,
                   identity.account.id,
                   identity.hosted_identity.id,
                   invalid
                 )
      end

      assert Participation.member_profile(project.id, identity.account.id).display_name ==
               "Member Label"
    end

    test "denies renaming another member's label and a departed member's own" do
      %{project: project, participant: participant, identity: identity} =
        project_with_participant()

      outsider = ParticipationFixtures.invited_identity_fixture()

      assert {:error, :unauthorized} =
               Participation.rename_member_profile(
                 project,
                 outsider.account.id,
                 outsider.hosted_identity.id,
                 "Intruder"
               )

      assert {:error, :unauthorized} =
               Participation.rename_member_profile(project, nil, nil, "Anonymous")

      {:ok, _departed} =
        participant
        |> SddOrchestrator.Participation.ProjectParticipant.departure_changeset(%{
          departure_reason: "left"
        })
        |> Repo.update()

      assert {:error, :unauthorized} =
               Participation.rename_member_profile(
                 project,
                 identity.account.id,
                 identity.hosted_identity.id,
                 "Too Late"
               )
    end
  end

  describe "preserve_historical_label/2" do
    test "keeps the last accepted label as non-interactive attribution" do
      %{project: project, identity: identity} = project_with_participant()

      {:ok, _renamed} =
        Participation.rename_member_profile(
          project,
          identity.account.id,
          identity.hosted_identity.id,
          "Final Label"
        )

      assert {:ok, "Final Label"} =
               Participation.preserve_historical_label(project.id, identity.account.id)

      profile = Participation.member_profile(project.id, identity.account.id)
      assert profile.state == "historical"
      assert profile.display_name == "Final Label"
      assert profile.account_id == identity.account.id
      refute ProjectMemberProfile.active?(profile)

      # The freed label becomes available to a current member again.
      newcomer = ParticipationFixtures.invited_identity_fixture()

      assert %ProjectMemberProfile{} =
               ParticipationFixtures.member_profile_fixture(project, newcomer.account, %{
                 role: "participant",
                 display_name: "Final Label"
               })
    end

    test "is safe for a member with no profile" do
      %{project: project} = project_with_participant()

      assert {:ok, nil} =
               Participation.preserve_historical_label(project.id, Ecto.UUID.generate())
    end
  end

  defp project_with_participant do
    result = ParticipationFixtures.hosted_project_fixture()

    ParticipationFixtures.member_profile_fixture(result.project, result.account, %{
      role: "owner",
      display_name: ParticipationFixtures.unique_display_name("Owner")
    })

    identity = ParticipationFixtures.invited_identity_fixture()

    participant =
      ParticipationFixtures.participant_fixture(result.project, identity.hosted_identity)

    profile =
      ParticipationFixtures.member_profile_fixture(result.project, identity.account, %{
        role: "participant",
        display_name: "Member Label"
      })

    Map.merge(result, %{identity: identity, participant: participant, profile: profile})
  end
end
