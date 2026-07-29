defmodule SddOrchestrator.Participation.CapabilitiesTest do
  use SddOrchestrator.DataCase, async: true

  alias SddOrchestrator.Participation
  alias SddOrchestrator.Participation.{Capabilities, ProjectParticipant}
  alias SddOrchestrator.ParticipationFixtures

  describe "capability matrix" do
    test "a participant receives project content capabilities only" do
      %{project: project, participant_actor: actor} = project_with_participant()

      assert Capabilities.capabilities(project, actor) == Capabilities.content_capabilities()

      for capability <- Capabilities.content_capabilities() do
        assert Capabilities.can?(project, actor, capability)
      end

      for capability <- Capabilities.management_capabilities() do
        refute Capabilities.can?(project, actor, capability)
      end
    end

    test "the owner adds membership and project settings but no credentials" do
      %{project: project, owner_actor: actor} = project_with_participant()

      for capability <-
            Capabilities.content_capabilities() ++ Capabilities.management_capabilities() do
        assert Capabilities.can?(project, actor, capability)
      end

      for capability <- Capabilities.credential_capabilities() do
        refute Capabilities.can?(project, actor, capability)
      end
    end

    test "no role reaches any credential capability" do
      %{project: project, owner_actor: owner, participant_actor: participant} =
        project_with_participant()

      for actor <- [owner, participant], capability <- Capabilities.credential_capabilities() do
        refute Capabilities.can?(project, actor, capability)
        refute capability in Capabilities.capabilities(project, actor)
      end
    end

    test "an unknown capability name is denied" do
      %{project: project, owner_actor: actor} = project_with_participant()

      refute Capabilities.can?(project, actor, :become_owner)
      refute Capabilities.can?(project, actor, :read_project_secrets)
    end
  end

  describe "fail-closed reads" do
    test "an outsider holds nothing in this project" do
      %{project: project} = project_with_participant()
      outsider = ParticipationFixtures.invited_identity_fixture()

      actor = %{account_id: outsider.account.id, hosted_identity_id: outsider.hosted_identity.id}

      assert Capabilities.capabilities(project, actor) == []
      refute Capabilities.can?(project, actor, :read_project)
      assert {:error, :unauthorized} = Capabilities.visible_project(project, actor)

      assert Capabilities.capabilities(project, %{}) == []
      assert Capabilities.capabilities(project, %{account_id: nil, hosted_identity_id: nil}) == []
    end

    test "participation in one project grants nothing in another" do
      %{project: project, participant_actor: actor} = project_with_participant()
      %{project: other_project} = project_with_participant()

      assert Capabilities.capabilities(project, actor) != []
      assert Capabilities.capabilities(other_project, actor) == []
      assert {:error, :unauthorized} = Capabilities.visible_project(other_project, actor)
    end

    test "an owner of one project holds nothing in another project or workspace" do
      %{owner_actor: actor} = project_with_participant()
      %{project: other_project} = project_with_participant()

      assert Capabilities.capabilities(other_project, actor) == []
    end

    test "capabilities end immediately when participation ends" do
      %{project: project, participant_actor: actor, participant: participant} =
        project_with_participant()

      assert Capabilities.can?(project, actor, :edit_specifications)

      {:ok, _departed} =
        participant
        |> ProjectParticipant.departure_changeset(%{departure_reason: "removed"})
        |> Repo.update()

      # The next decision re-reads participation; nothing is cached.
      assert Capabilities.capabilities(project, actor) == []
      refute Capabilities.can?(project, actor, :read_project)
      assert {:error, :unauthorized} = Capabilities.visible_project(project, actor)
    end
  end

  describe "protected fields" do
    test "a member reads only the approved project fields" do
      %{project: project, participant_actor: actor} = project_with_participant()

      assert {:ok, visible} = Capabilities.visible_project(project, actor)
      assert Map.keys(visible) |> Enum.sort() == [:id, :name, :storage_mode]
      assert visible.id == project.id
      assert visible.name == project.name

      for protected <- [:workspace_id, :repository_provider, :canonical_repository_id] do
        refute Map.has_key?(visible, protected)
      end
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

    ParticipationFixtures.member_profile_fixture(result.project, identity.account, %{
      role: "participant",
      display_name: ParticipationFixtures.unique_display_name("Member")
    })

    assert Participation.active_participant(result.project.id, identity.hosted_identity.id)

    Map.merge(result, %{
      participant: participant,
      participant_actor: %{
        account_id: identity.account.id,
        hosted_identity_id: identity.hosted_identity.id
      },
      owner_actor: %{account_id: result.account.id, hosted_identity_id: nil}
    })
  end
end
