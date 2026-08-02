defmodule SddOrchestrator.Delivery.ParticipantGuardTest do
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Delivery.ParticipantGuard
  alias SddOrchestrator.Participation
  alias SddOrchestrator.Participation.Revocations
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

  describe "authorize/2" do
    test "resolves the current owner and participant by project display name" do
      %{project: project, owner_actor: owner_actor, participant_actor: participant_actor} =
        joined()

      assert {:ok, owner} = ParticipantGuard.authorize(project.id, owner_actor)
      assert owner.role == :owner
      assert ParticipantGuard.display_name(owner) =~ "Owner"

      assert {:ok, participant} = ParticipantGuard.authorize(project.id, participant_actor)
      assert participant.role == :participant
      assert ParticipantGuard.display_name(participant) == "Member Label"
    end

    test "never returns an email address for any member" do
      %{project: project, owner_actor: owner_actor, identity: identity} = joined()

      members = ParticipantGuard.current_members(project.id, owner_actor)
      assert length(members) == 2

      for member <- members do
        assert Enum.sort(Map.keys(member)) ==
                 [:account_id, :display_name, :hosted_identity_id, :presentation_state, :role]

        refute member.display_name =~ "@"
      end

      refute inspect(members) =~ identity.external_identity.display_identifier
    end

    test "denies an absent, stale, and cross-project identity identically" do
      %{project: project, participant_actor: actor} = joined()
      %{project: other_project} = joined()
      outsider = ParticipationFixtures.invited_identity_fixture()

      outsider_actor = %{
        account_id: outsider.account.id,
        hosted_identity_id: outsider.hosted_identity.id
      }

      assert {:error, :unauthorized} = ParticipantGuard.authorize(project.id, outsider_actor)
      assert {:error, :unauthorized} = ParticipantGuard.authorize(project.id, %{})
      assert {:error, :unauthorized} = ParticipantGuard.authorize(project.id, nil)
      assert {:error, :unauthorized} = ParticipantGuard.authorize(other_project.id, actor)
    end

    test "an unknown project is indistinguishable from an unauthorized one" do
      %{project: project, participant_actor: actor} = joined()
      outsider = ParticipationFixtures.invited_identity_fixture()

      outsider_actor = %{
        account_id: outsider.account.id,
        hosted_identity_id: outsider.hosted_identity.id
      }

      unknown = ParticipantGuard.authorize(Ecto.UUID.generate(), actor)
      malformed = ParticipantGuard.authorize("not-an-id", actor)
      unauthorized = ParticipantGuard.authorize(project.id, outsider_actor)

      assert unknown == {:error, :unauthorized}
      assert malformed == unauthorized
      assert unknown == unauthorized

      # Listing a project the caller cannot read discloses nothing either.
      assert ParticipantGuard.current_members(Ecto.UUID.generate(), actor) == []
      assert ParticipantGuard.current_members(project.id, outsider_actor) == []
    end
  end

  describe "authorize_action/3" do
    test "permits every protected action for a current participant" do
      %{project: project, participant_actor: actor} = joined()

      for action <- ParticipantGuard.protected_actions() do
        assert {:ok, member} = ParticipantGuard.authorize_action(project.id, actor, action)
        assert member.role == :participant
      end
    end

    test "permits every protected action for the project owner" do
      %{project: project, owner_actor: actor} = joined()

      for action <- ParticipantGuard.protected_actions() do
        assert {:ok, %{role: :owner}} =
                 ParticipantGuard.authorize_action(project.id, actor, action)
      end
    end

    test "denies an unknown action and a non-member" do
      %{project: project, participant_actor: actor} = joined()
      outsider = ParticipationFixtures.invited_identity_fixture()

      assert {:error, :unauthorized} =
               ParticipantGuard.authorize_action(project.id, actor, :delete_project)

      assert {:error, :unauthorized} =
               ParticipantGuard.authorize_action(project.id, actor, :read_credentials)

      assert {:error, :unauthorized} =
               ParticipantGuard.authorize_action(
                 project.id,
                 %{
                   account_id: outsider.account.id,
                   hosted_identity_id: outsider.hosted_identity.id
                 },
                 :comment
               )
    end

    test "fails closed immediately after removal and after leaving" do
      %{project: project, account: owner_account, participant_actor: actor, identity: identity} =
        joined()

      assert {:ok, _member} = ParticipantGuard.authorize_action(project.id, actor, :comment)

      {:ok, _removed} = Revocations.remove(project, owner_account.id, identity.hosted_identity.id)

      for action <- ParticipantGuard.protected_actions() do
        assert {:error, :unauthorized} =
                 ParticipantGuard.authorize_action(project.id, actor, action)
      end

      assert {:error, :unauthorized} = ParticipantGuard.authorize(project.id, actor)
      assert ParticipantGuard.current_members(project.id, actor) == []
    end
  end

  describe "responsibility fallback" do
    test "resolves the immutable owner" do
      %{project: project, account: owner_account} = joined()

      assert {:ok, owner} = ParticipantGuard.owner(project.id)
      assert owner.role == :owner
      assert owner.account_id == owner_account.id
      refute Map.has_key?(owner, :email)

      assert {:error, :unauthorized} = ParticipantGuard.owner(Ecto.UUID.generate())
    end
  end

  describe "read-only guarantee" do
    test "guard calls change no participation state" do
      %{project: project, participant_actor: actor, identity: identity} = joined()

      before_state = Participation.active_participant(project.id, identity.hosted_identity.id)
      before_profile = Participation.member_profile(project.id, identity.account.id)

      ParticipantGuard.authorize(project.id, actor)
      ParticipantGuard.authorize_action(project.id, actor, :start_run)
      ParticipantGuard.current_members(project.id, actor)
      ParticipantGuard.owner(project.id)

      after_state = Participation.active_participant(project.id, identity.hosted_identity.id)
      after_profile = Participation.member_profile(project.id, identity.account.id)

      assert after_state.id == before_state.id
      assert after_state.updated_at == before_state.updated_at
      assert after_profile.updated_at == before_profile.updated_at
      assert Revocations.pending() == []
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

    Map.merge(result, %{
      identity: identity,
      owner_actor: %{account_id: result.account.id, hosted_identity_id: nil},
      participant_actor: %{
        account_id: identity.account.id,
        hosted_identity_id: identity.hosted_identity.id
      }
    })
  end
end
