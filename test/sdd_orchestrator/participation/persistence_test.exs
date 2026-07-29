defmodule SddOrchestrator.Participation.PersistenceTest do
  use SddOrchestrator.DataCase, async: true

  alias Ecto.Adapters.SQL
  alias SddOrchestrator.Participation
  alias SddOrchestrator.Participation.{DisplayName, ProjectMemberProfile, ProjectParticipant}
  alias SddOrchestrator.ParticipationFixtures
  alias SddOrchestrator.Projects.Project

  describe "immutable owner derivation" do
    test "resolves the hosted project owner from the ownership boundary" do
      %{project: project, account: account, workspace: workspace} = hosted_project()

      assert {:ok, owner} = Participation.owner(project)
      assert owner.account_id == account.id
      assert owner.workspace_id == workspace.id
      assert owner.project_id == project.id

      assert {:ok, ^owner} = Participation.owner(project.id)
      assert Participation.owner?(project, account.id)
    end

    test "denies ownership to another account and to a missing project" do
      %{project: project} = hosted_project()
      %{account: other_account} = hosted_project()

      refute Participation.owner?(project, other_account.id)
      refute Participation.owner?(project, nil)
      assert {:error, :project_not_found} = Participation.owner(Ecto.UUID.generate())
      assert {:error, :project_not_found} = Participation.owner("not-an-id")
    end

    test "reports no hosted owner for a device-authoritative project" do
      device_project = %Project{
        id: Ecto.UUID.generate(),
        workspace_id: Ecto.UUID.generate(),
        storage_mode: "device"
      }

      assert {:error, :not_hosted_project} = Participation.owner(device_project)
      refute Participation.owner?(device_project, Ecto.UUID.generate())
    end

    test "the hosted database refuses to store a device project in a hosted workspace" do
      %{workspace: workspace} = hosted_project()

      assert {:error, changeset} =
               %Project{}
               |> Project.changeset(%{
                 name: "device project",
                 workspace_id: workspace.id,
                 storage_mode: "device"
               })
               |> Repo.insert()

      assert errors_on(changeset).workspace_id != []
    end
  end

  describe "participant authorization" do
    test "binds one active authorization to a stable hosted identity" do
      %{project: project} = hosted_project()
      identity = invited_identity()

      participant =
        ParticipationFixtures.participant_fixture(project, identity.hosted_identity)

      assert participant.state == "active"
      assert participant.role == "participant"
      assert participant.hosted_identity_id == identity.hosted_identity.id
      assert ProjectParticipant.active?(participant)

      assert %ProjectParticipant{id: id} =
               Participation.active_participant(project.id, identity.hosted_identity.id)

      assert id == participant.id

      assert Participation.active_participants(project.id) |> Enum.map(& &1.id) == [
               participant.id
             ]
    end

    test "returns no authorization before acceptance, after departure, or for another project" do
      %{project: project} = hosted_project()
      %{project: other_project} = hosted_project()
      identity = invited_identity()

      # An invited person who has not accepted has no authorization at all.
      refute Participation.active_participant(project.id, identity.hosted_identity.id)
      assert Participation.active_participants(project.id) == []

      participant = ParticipationFixtures.participant_fixture(project, identity.hosted_identity)

      refute Participation.active_participant(other_project.id, identity.hosted_identity.id)
      refute Participation.active_participant(project.id, nil)

      {:ok, departed} =
        participant
        |> ProjectParticipant.departure_changeset(%{departure_reason: "removed"})
        |> Repo.update()

      assert departed.state == "departed"
      assert departed.departed_at
      refute ProjectParticipant.active?(departed)
      refute Participation.active_participant(project.id, identity.hosted_identity.id)
      assert Participation.active_participants(project.id) == []
    end

    test "rejects a second active authorization for the same identity and project" do
      %{project: project} = hosted_project()
      identity = invited_identity()

      ParticipationFixtures.participant_fixture(project, identity.hosted_identity)

      assert {:error, changeset} =
               %ProjectParticipant{}
               |> ProjectParticipant.activation_changeset(%{
                 project_id: project.id,
                 hosted_identity_id: identity.hosted_identity.id
               })
               |> Repo.insert()

      assert "already participates in this project" in errors_on(changeset).hosted_identity_id
    end

    test "allows a fresh authorization only after the prior one departed" do
      %{project: project} = hosted_project()
      identity = invited_identity()

      participant = ParticipationFixtures.participant_fixture(project, identity.hosted_identity)

      {:ok, _departed} =
        participant
        |> ProjectParticipant.departure_changeset(%{departure_reason: "left"})
        |> Repo.update()

      rejoined = ParticipationFixtures.participant_fixture(project, identity.hosted_identity)

      assert rejoined.id != participant.id

      assert Participation.active_participant(project.id, identity.hosted_identity.id).id ==
               rejoined.id
    end

    test "rejects an unsupported role and an unknown project or identity" do
      %{project: project} = hosted_project()
      identity = invited_identity()

      assert {:error, changeset} =
               %ProjectParticipant{}
               |> ProjectParticipant.activation_changeset(%{
                 project_id: project.id,
                 hosted_identity_id: identity.hosted_identity.id,
                 role: "owner"
               })
               |> Repo.insert()

      assert "is invalid" in errors_on(changeset).role

      assert {:error, changeset} =
               %ProjectParticipant{}
               |> ProjectParticipant.activation_changeset(%{
                 project_id: Ecto.UUID.generate(),
                 hosted_identity_id: identity.hosted_identity.id
               })
               |> Repo.insert()

      assert errors_on(changeset).project_id != []
    end

    test "releases only the identity link of a departed authorization" do
      %{project: project} = hosted_project()
      identity = invited_identity()

      participant = ParticipationFixtures.participant_fixture(project, identity.hosted_identity)

      {:ok, departed} =
        participant
        |> ProjectParticipant.departure_changeset(%{departure_reason: "removed"})
        |> Repo.update()

      {:ok, released} =
        departed |> ProjectParticipant.identity_release_changeset() |> Repo.update()

      assert is_nil(released.hosted_identity_id)
      assert released.state == "departed"
      assert released.departure_reason == "removed"
    end

    test "the database rejects an active row without an identity" do
      %{project: project} = hosted_project()

      assert_raise Postgrex.Error, ~r/project_participants_state_shape/, fn ->
        SQL.query!(
          Repo,
          """
          INSERT INTO project_participants
            (id, project_id, role, state, joined_at, inserted_at, updated_at)
          VALUES ($1, $2, 'participant', 'active', now(), now(), now())
          """,
          [Ecto.UUID.dump!(Ecto.UUID.generate()), Ecto.UUID.dump!(project.id)]
        )
      end
    end
  end

  describe "project display profiles" do
    test "stores the accepted spelling and its case-insensitive comparison key" do
      %{project: project, account: account} = hosted_project()

      profile =
        ParticipationFixtures.member_profile_fixture(project, account, %{
          role: "owner",
          display_name: "  Ada Lovelace  "
        })

      assert profile.display_name == "Ada Lovelace"
      assert profile.display_name_key == "ada lovelace"
      assert profile.role == "owner"
      assert profile.state == "active"
      assert ProjectMemberProfile.active?(profile)
      assert Participation.owner_profile(project.id).id == profile.id
      assert Participation.member_profile(project.id, account.id).id == profile.id
    end

    test "rejects a conflicting label without allocating an automatic suffix" do
      %{project: project, account: owner_account} = hosted_project()
      identity = invited_identity()

      ParticipationFixtures.member_profile_fixture(project, owner_account, %{
        role: "owner",
        display_name: "Ada Lovelace"
      })

      assert {:error, changeset} =
               %ProjectMemberProfile{}
               |> ProjectMemberProfile.changeset(%{
                 project_id: project.id,
                 account_id: identity.account.id,
                 role: "participant",
                 display_name: "ADA lovelace"
               })
               |> Repo.insert()

      assert "is already used in this project" in errors_on(changeset).display_name
    end

    test "scopes the uniqueness boundary to one project" do
      %{project: project, account: account} = hosted_project()
      %{project: other_project, account: other_account} = hosted_project()

      ParticipationFixtures.member_profile_fixture(project, account, %{
        role: "owner",
        display_name: "Shared Label"
      })

      assert %ProjectMemberProfile{} =
               ParticipationFixtures.member_profile_fixture(other_project, other_account, %{
                 role: "owner",
                 display_name: "Shared Label"
               })
    end

    test "rejects blank, oversized, control-character, and email-shaped labels" do
      %{project: project, account: account} = hosted_project()

      for invalid <- ["", "   ", String.duplicate("n", 81), "badlabel", "owner@example.com"] do
        assert {:error, changeset} =
                 %ProjectMemberProfile{}
                 |> ProjectMemberProfile.changeset(%{
                   project_id: project.id,
                   account_id: account.id,
                   role: "owner",
                   display_name: invalid
                 })
                 |> Repo.insert()

        assert errors_on(changeset).display_name != []
      end
    end

    test "rejects an unsupported role and a second profile for one account" do
      %{project: project, account: account} = hosted_project()

      assert {:error, changeset} =
               %ProjectMemberProfile{}
               |> ProjectMemberProfile.changeset(%{
                 project_id: project.id,
                 account_id: account.id,
                 role: "administrator",
                 display_name: "Ada"
               })
               |> Repo.insert()

      assert "is invalid" in errors_on(changeset).role

      ParticipationFixtures.member_profile_fixture(project, account, %{role: "owner"})

      assert {:error, changeset} =
               %ProjectMemberProfile{}
               |> ProjectMemberProfile.changeset(%{
                 project_id: project.id,
                 account_id: account.id,
                 role: "participant",
                 display_name: "Another Label"
               })
               |> Repo.insert()

      assert "already has a profile in this project" in errors_on(changeset).account_id
    end

    test "renames only the label and preserves stable identity and role" do
      %{project: project, account: account} = hosted_project()

      profile =
        ParticipationFixtures.member_profile_fixture(project, account, %{
          role: "owner",
          display_name: "First Label"
        })

      {:ok, renamed} =
        profile
        |> ProjectMemberProfile.rename_changeset(%{display_name: " Second Label "})
        |> Repo.update()

      assert renamed.id == profile.id
      assert renamed.account_id == account.id
      assert renamed.role == "owner"
      assert renamed.display_name == "Second Label"
      assert renamed.display_name_key == "second label"
    end

    test "preserves the last accepted label as historical attribution" do
      %{project: project, account: account} = hosted_project()
      identity = invited_identity()

      profile =
        ParticipationFixtures.member_profile_fixture(project, account, %{
          role: "participant",
          display_name: "Departing Member"
        })

      {:ok, historical} =
        profile |> ProjectMemberProfile.historical_changeset() |> Repo.update()

      assert historical.state == "historical"
      assert historical.display_name == "Departing Member"
      assert historical.account_id == account.id
      refute ProjectMemberProfile.active?(historical)

      # The freed label may be reused by a current member.
      assert %ProjectMemberProfile{} =
               ParticipationFixtures.member_profile_fixture(project, identity.account, %{
                 role: "participant",
                 display_name: "Departing Member"
               })
    end

    test "anonymization removes the account link without deleting the profile row" do
      %{project: project, account: account} = hosted_project()

      profile =
        ParticipationFixtures.member_profile_fixture(project, account, %{
          role: "participant",
          display_name: "Identifiable Member"
        })

      {:ok, historical} =
        profile |> ProjectMemberProfile.historical_changeset() |> Repo.update()

      {:ok, anonymized} =
        historical |> ProjectMemberProfile.anonymization_changeset() |> Repo.update()

      assert anonymized.id == profile.id
      assert anonymized.state == "anonymized"
      assert is_nil(anonymized.account_id)
      assert anonymized.anonymized_at
      assert anonymized.display_name == ProjectMemberProfile.anonymous_label()

      assert anonymized.display_name_key ==
               DisplayName.key(ProjectMemberProfile.anonymous_label())

      refute Participation.member_profile(project.id, account.id)
    end

    test "the database rejects an anonymized row that still names an account" do
      %{project: project, account: account} = hosted_project()

      assert_raise Postgrex.Error, ~r/project_member_profiles_anonymized_shape/, fn ->
        SQL.query!(
          Repo,
          """
          INSERT INTO project_member_profiles
            (id, project_id, account_id, role, state, display_name, display_name_key,
             anonymized_at, inserted_at, updated_at)
          VALUES ($1, $2, $3, 'participant', 'anonymized', 'Label', 'label', now(), now(), now())
          """,
          [
            Ecto.UUID.dump!(Ecto.UUID.generate()),
            Ecto.UUID.dump!(project.id),
            Ecto.UUID.dump!(account.id)
          ]
        )
      end
    end
  end

  describe "rollback" do
    test "a failed profile insertion leaves no participation state" do
      %{project: project, account: account} = hosted_project()
      identity = invited_identity()

      result =
        Repo.transaction(fn ->
          ParticipationFixtures.participant_fixture(project, identity.hosted_identity)

          %ProjectMemberProfile{}
          |> ProjectMemberProfile.changeset(%{
            project_id: project.id,
            account_id: account.id,
            role: "participant",
            display_name: ""
          })
          |> Repo.insert()
          |> case do
            {:ok, profile} -> profile
            {:error, changeset} -> Repo.rollback(changeset)
          end
        end)

      assert {:error, %Ecto.Changeset{}} = result
      assert Participation.active_participants(project.id) == []
      refute Participation.member_profile(project.id, account.id)
    end
  end

  defp hosted_project, do: ParticipationFixtures.hosted_project_fixture()

  defp invited_identity, do: ParticipationFixtures.invited_identity_fixture()
end
