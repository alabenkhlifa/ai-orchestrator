defmodule SddOrchestrator.Delivery.FeatureSpecificationCreationTest do
  @moduledoc """
  Proof that a feature owns a specification from the moment it exists (Task 1
  of specs/41-feature-delivery-from-the-ui, AC-01).
  """
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Delivery.{Feature, Features, Readiness}
  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.Repo
  alias SddOrchestrator.SpecificationStore

  setup do
    context = DeliveryFixtures.delivery_project_fixture()

    %{
      project: context.project,
      workspace: context.workspace,
      account: context.account,
      participant_account: context.identity.account,
      owner: context.owner_actor,
      participant: context.participant_actor
    }
  end

  defp expected_headings do
    Enum.map(Readiness.guided_structure(), &"## #{&1.label}")
  end

  describe "creation writes the feature's own specification" do
    test "the created feature answers a specification whose current revision holds the four empty headings",
         %{project: project, workspace: workspace, owner: owner} do
      assert {:ok, feature} = Features.create(project.id, owner, %{title: "Search filters"})

      assert is_binary(feature.specification_id)

      assert {:ok, ^feature} =
               Features.fetch_by_specification(project.id, feature.specification_id)

      assert {:ok, current} =
               SpecificationStore.get_current(workspace, project.id, feature.specification_id)

      assert current.specification.title == "Search filters"

      assert current.revision.requirements_document ==
               Enum.join(expected_headings(), "\n\n") <> "\n"

      # Every heading is present and nothing is written under any of them.
      for heading <- expected_headings() do
        assert String.contains?(current.revision.requirements_document, heading <> "\n")
      end

      assert current.revision.design_document =~ "coding agent"
      assert current.revision.tasks_document =~ "coding agent"
    end

    test "a participant creates the feature, the specification lands in the owner's store, and the participant is the revision's actor",
         %{
           project: project,
           workspace: workspace,
           participant: participant,
           participant_account: participant_account,
           account: owner_account
         } do
      assert {:ok, feature} = Features.create(project.id, participant, %{title: "Saved views"})

      assert feature.creator_account_id == participant_account.id
      refute participant_account.id == owner_account.id

      # Read under the OWNER's authority: that is where the specification lives.
      assert {:ok, current} =
               SpecificationStore.get_current(workspace, project.id, feature.specification_id)

      assert current.revision.actor_ref == participant_account.id
    end

    test "a refused specification leaves no feature behind", %{project: project, owner: owner} do
      before_count = feature_count(project.id)

      # Refused before the store writes anything.
      with_specification_limits([max_specifications_per_project: 0], fn ->
        assert {:error, :specification_limit_exceeded} =
                 Features.create(project.id, owner, %{title: "Never created"})
      end)

      # Refused after the store has opened its own transaction, which is the
      # path that has to roll back rather than just return early.
      with_specification_limits([max_title_bytes: 1], fn ->
        assert {:error, %Ecto.Changeset{}} =
                 Features.create(project.id, owner, %{title: "Also never created"})
      end)

      assert feature_count(project.id) == before_count
      assert Repo.get_by(Feature, project_id: project.id, title: "Never created") == nil
      assert Repo.get_by(Feature, project_id: project.id, title: "Also never created") == nil
    end

    test "the board still lists the created feature in Draft with every column present", %{
      project: project,
      owner: owner
    } do
      assert {:ok, feature} = Features.create(project.id, owner, %{title: "Board entry"})

      assert {:ok, board} = Features.board(project.id, owner)

      assert Map.keys(board) |> Enum.sort() == Enum.sort(Feature.columns())
      assert [listed] = board["draft"]
      assert listed.id == feature.id
      assert listed.title == "Board entry"
      assert listed.lifecycle_column == "draft"
      assert listed.status == "none"
      assert listed.state_version == 1
      assert listed.specification_id == feature.specification_id

      for column <- Feature.columns() -- ["draft"] do
        assert board[column] == []
      end
    end
  end

  defp feature_count(project_id) do
    Repo.aggregate(from(feature in Feature, where: feature.project_id == ^project_id), :count)
  end

  # Tightening a real store limit is a real refusal path, so the rollback is
  # proved through the store's own rules rather than through fault injection.
  defp with_specification_limits(limits, fun) do
    previous = Application.get_env(:sdd_orchestrator, :specification_limits)

    Application.put_env(:sdd_orchestrator, :specification_limits, limits)

    try do
      fun.()
    after
      if previous do
        Application.put_env(:sdd_orchestrator, :specification_limits, previous)
      else
        Application.delete_env(:sdd_orchestrator, :specification_limits)
      end
    end
  end
end
