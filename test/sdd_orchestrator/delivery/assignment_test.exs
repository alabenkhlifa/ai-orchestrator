defmodule SddOrchestrator.Delivery.AssignmentTest do
  @moduledoc """
  Proof for assignment and responsibility (Task 9).

  Assignment is an editable field; responsibility is a derived answer that must
  always resolve to someone who is authorized right now. The tests pin both:
  who may assign, who may be assigned, what happens when the assignee or
  creator leaves, and that nothing on this path exposes a participant email.
  """
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Delivery.{ActivityEntry, Assignment, Feature}
  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.Participation.Revocations
  alias SddOrchestrator.ParticipationDeliveryDouble
  alias SddOrchestrator.ParticipationFixtures
  alias SddOrchestrator.Repo

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

    context = DeliveryFixtures.delivery_project_fixture()
    feature = DeliveryFixtures.feature_fixture(context.project, context.account)

    %{
      context: context,
      project: context.project,
      feature: feature,
      owner_account: context.account,
      participant_account: context.identity.account,
      owner: context.owner_actor,
      participant: context.participant_actor
    }
  end

  describe "the participant selector" do
    test "offers exactly the project's current members", %{
      project: project,
      owner: owner,
      owner_account: owner_account,
      participant_account: participant_account
    } do
      members = Assignment.assignable_members(project.id, owner)

      assert Enum.map(members, & &1.account_id) |> Enum.sort() ==
               Enum.sort([owner_account.id, participant_account.id])
    end

    test "exposes a project display name and no email", %{project: project, owner: owner} do
      for member <- Assignment.assignable_members(project.id, owner) do
        assert is_binary(member.display_name)
        refute member.display_name =~ "@"
        refute Map.has_key?(member, :email)
      end
    end

    test "is empty for an outsider rather than disclosing membership", %{project: project} do
      assert Assignment.assignable_members(project.id, %{account_id: Ecto.UUID.generate()}) == []
      assert Assignment.assignable_members(project.id, %{}) == []
    end

    test "no longer offers a participant who left", %{
      project: project,
      context: context,
      owner: owner,
      owner_account: owner_account
    } do
      {:ok, _removed} =
        Revocations.remove(project, owner_account.id, context.identity.hosted_identity.id)

      assert Enum.map(Assignment.assignable_members(project.id, owner), & &1.account_id) ==
               [owner_account.id]
    end
  end

  describe "assigning" do
    test "any current participant may assign any current participant [AC-07]", %{
      project: project,
      feature: feature,
      participant: participant,
      owner_account: owner_account
    } do
      assert {:ok, assigned} =
               Assignment.assign(project.id, participant, feature, owner_account.id)

      assert assigned.assigned_account_id == owner_account.id
      assert Repo.get!(Feature, feature.id).assigned_account_id == owner_account.id
    end

    test "`Assign to me` sets the acting participant [AC-08]", %{
      project: project,
      feature: feature,
      participant: participant,
      participant_account: participant_account
    } do
      assert {:ok, assigned} = Assignment.assign_to_me(project.id, participant, feature)

      assert assigned.assigned_account_id == participant_account.id
    end

    test "clearing the assignment returns responsibility to the creator", %{
      project: project,
      feature: feature,
      owner: owner,
      participant_account: participant_account,
      owner_account: owner_account
    } do
      {:ok, assigned} = Assignment.assign(project.id, owner, feature, participant_account.id)

      assert {:ok, cleared} = Assignment.unassign(project.id, owner, assigned)
      refute cleared.assigned_account_id

      assert {:ok, member} = Assignment.responsible(project.id, cleared)
      assert member.account_id == owner_account.id
    end

    test "rejects a target who is not a current participant", %{
      project: project,
      feature: feature,
      owner: owner
    } do
      outsider = ParticipationFixtures.invited_identity_fixture()

      assert {:error, :invalid_target} =
               Assignment.assign(project.id, owner, feature, outsider.account.id)

      refute Repo.get!(Feature, feature.id).assigned_account_id
    end

    test "rejects a target who left after the selector was rendered", %{
      project: project,
      feature: feature,
      context: context,
      owner: owner,
      owner_account: owner_account
    } do
      stale_target = context.identity.account.id

      {:ok, _removed} =
        Revocations.remove(project, owner_account.id, context.identity.hosted_identity.id)

      assert {:error, :invalid_target} =
               Assignment.assign(project.id, owner, feature, stale_target)
    end

    test "denies an outsider and a departed participant without changing anything", %{
      project: project,
      feature: feature,
      context: context,
      owner_account: owner_account,
      participant: participant,
      participant_account: participant_account
    } do
      assert {:error, :unauthorized} =
               Assignment.assign(
                 project.id,
                 %{account_id: Ecto.UUID.generate()},
                 feature,
                 owner_account.id
               )

      {:ok, _removed} =
        Revocations.remove(project, owner_account.id, context.identity.hosted_identity.id)

      assert {:error, :unauthorized} =
               Assignment.assign(project.id, participant, feature, participant_account.id)

      refute Repo.get!(Feature, feature.id).assigned_account_id
    end

    test "never assigns a feature from another project", %{owner: owner, feature: feature} do
      other = DeliveryFixtures.delivery_project_fixture()

      assert {:error, :unauthorized} =
               Assignment.assign(other.project.id, owner, feature, other.account.id)
    end

    test "rejects a stale feature rather than overwriting a newer assignment", %{
      project: project,
      feature: feature,
      owner: owner,
      participant_account: participant_account,
      owner_account: owner_account
    } do
      {:ok, _first} = Assignment.assign(project.id, owner, feature, participant_account.id)

      # `feature` still carries the pre-assignment state version.
      assert {:error, :stale_state} =
               Assignment.assign(project.id, owner, feature, owner_account.id)

      assert Repo.get!(Feature, feature.id).assigned_account_id == participant_account.id
    end
  end

  describe "assignment activity" do
    test "records one entry naming who acted and what changed", %{
      project: project,
      feature: feature,
      owner: owner,
      owner_account: owner_account,
      participant_account: participant_account
    } do
      {:ok, _assigned} = Assignment.assign(project.id, owner, feature, participant_account.id)

      assert [entry] = Repo.all(ActivityEntry)
      assert entry.type == "assignment_changed"
      assert entry.actor_kind == "participant"
      assert entry.actor_account_id == owner_account.id
      assert entry.payload["action"] == "assigned"
      assert entry.payload["assigned_account_id"] == participant_account.id
      assert entry.sequence == 1
    end

    test "distinguishes self-assignment and clearing", %{
      project: project,
      feature: feature,
      participant: participant
    } do
      {:ok, assigned} = Assignment.assign_to_me(project.id, participant, feature)
      {:ok, _cleared} = Assignment.unassign(project.id, participant, assigned)

      actions =
        ActivityEntry
        |> Repo.all()
        |> Enum.sort_by(& &1.sequence)
        |> Enum.map(& &1.payload["action"])

      assert actions == ["self_assigned", "unassigned"]
    end

    test "carries no participant email", %{
      project: project,
      feature: feature,
      owner: owner,
      participant_account: participant_account
    } do
      {:ok, _assigned} = Assignment.assign(project.id, owner, feature, participant_account.id)

      encoded =
        ActivityEntry
        |> Repo.all()
        |> Enum.map(&ActivityEntry.to_value/1)
        |> Jason.encode!()

      refute encoded =~ "@example.com"
      refute encoded =~ "@"
    end

    test "records nothing when the assignment is rejected", %{
      project: project,
      feature: feature,
      owner: owner
    } do
      outsider = ParticipationFixtures.invited_identity_fixture()

      assert {:error, :invalid_target} =
               Assignment.assign(project.id, owner, feature, outsider.account.id)

      assert Repo.aggregate(ActivityEntry, :count) == 0
    end
  end

  describe "responsibility resolution" do
    test "resolves the assignee first, even when the creator is someone else", %{
      project: project,
      feature: feature,
      owner: owner,
      participant_account: participant_account
    } do
      {:ok, assigned} = Assignment.assign(project.id, owner, feature, participant_account.id)

      assert {:ok, member} = Assignment.responsible(project.id, assigned)
      assert member.account_id == participant_account.id
    end

    test "falls back to the creator when nobody is assigned", %{
      project: project,
      feature: feature,
      owner_account: owner_account
    } do
      assert {:ok, member} = Assignment.responsible(project.id, feature)
      assert member.account_id == owner_account.id
    end

    test "falls back to the owner when the assignee is no longer a participant", %{
      project: project,
      context: context,
      owner: owner,
      owner_account: owner_account,
      participant_account: participant_account
    } do
      creator_feature =
        DeliveryFixtures.feature_fixture(project, context.identity.account)

      {:ok, assigned} =
        Assignment.assign(project.id, owner, creator_feature, participant_account.id)

      {:ok, _removed} =
        Revocations.remove(project, owner_account.id, context.identity.hosted_identity.id)

      # Both the assignee and the creator have left, so the immutable owner is
      # the deterministic fallback rather than a former participant.
      assert {:ok, member} = Assignment.responsible(project.id, assigned)
      assert member.account_id == owner_account.id
      assert member.role == :owner
    end

    test "falls back to the owner when the creator left and nobody is assigned", %{
      project: project,
      context: context,
      owner_account: owner_account
    } do
      feature = DeliveryFixtures.feature_fixture(project, context.identity.account)

      {:ok, _removed} =
        Revocations.remove(project, owner_account.id, context.identity.hosted_identity.id)

      assert {:ok, member} = Assignment.responsible(project.id, feature)
      assert member.account_id == owner_account.id
    end

    test "resolves identically for a background caller with no acting identity", %{
      project: project,
      feature: feature,
      owner_account: owner_account
    } do
      assert {:ok, member} = Assignment.responsible(project.id, feature)
      assert member.account_id == owner_account.id
    end
  end

  describe "presentation labels [AC-31]" do
    test "presents creator and assignee by project display name", %{
      project: project,
      feature: feature,
      owner: owner,
      participant_account: participant_account
    } do
      {:ok, assigned} = Assignment.assign(project.id, owner, feature, participant_account.id)

      labels = Assignment.labels(project.id, assigned)

      assert labels.creator =~ "Owner"
      assert labels.assignee =~ "Member"
      refute labels.creator =~ "@"
      refute labels.assignee =~ "@"
    end

    test "has no label for a departed member rather than inventing one", %{
      project: project,
      context: context,
      owner: owner,
      owner_account: owner_account,
      participant_account: participant_account
    } do
      {:ok, assigned} =
        Assignment.assign(project.id, owner, feature_of(project, context), participant_account.id)

      {:ok, _removed} =
        Revocations.remove(project, owner_account.id, context.identity.hosted_identity.id)

      labels = Assignment.labels(project.id, assigned)

      refute labels.assignee
    end

    test "has no assignee label when nobody is assigned", %{project: project, feature: feature} do
      assert %{assignee: nil} = Assignment.labels(project.id, feature)
    end
  end

  defp feature_of(project, context),
    do: DeliveryFixtures.feature_fixture(project, context.account)
end
