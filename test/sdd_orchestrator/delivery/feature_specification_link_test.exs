defmodule SddOrchestrator.Delivery.FeatureSpecificationLinkTest do
  @moduledoc """
  Proof for the owner-only feature-specification link and the published
  `fetch_by_specification/2` capability read (Task 1 of
  specs/35-guided-delivery-feature-specification-link).
  """
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Delivery.{Feature, Features}
  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.Repo
  alias SddOrchestrator.SpecificationFixtures

  setup do
    context = DeliveryFixtures.delivery_project_fixture()
    feature = DeliveryFixtures.feature_fixture(context.project, context.account)

    %{
      project: context.project,
      workspace: context.workspace,
      account: context.account,
      feature: feature,
      owner: context.owner_actor,
      participant: context.participant_actor
    }
  end

  defp specification(workspace, project, overrides \\ %{}) do
    SpecificationFixtures.hosted_specification(workspace, project, overrides)
  end

  describe "linking" do
    test "the owner links a feature to a current specification, and the read resolves it", %{
      project: project,
      workspace: workspace,
      feature: feature,
      owner: owner
    } do
      current = specification(workspace, project)

      assert {:ok, linked} =
               Features.link_specification(
                 workspace,
                 project.id,
                 owner,
                 feature,
                 current.specification.id
               )

      assert linked.specification_id == current.specification.id

      assert {:ok, resolved} =
               Features.fetch_by_specification(project.id, current.specification.id)

      assert resolved.id == feature.id
    end

    test "the owner changes an existing link: the old link no longer resolves, the new one does, and other fields are unchanged",
         %{project: project, workspace: workspace, feature: feature, owner: owner} do
      first = specification(workspace, project, %{title: "First"})
      second = specification(workspace, project, %{title: "Second"})

      {:ok, linked} =
        Features.link_specification(workspace, project.id, owner, feature, first.specification.id)

      assert {:ok, relinked} =
               Features.link_specification(
                 workspace,
                 project.id,
                 owner,
                 linked,
                 second.specification.id
               )

      assert relinked.specification_id == second.specification.id
      assert relinked.lifecycle_column == feature.lifecycle_column
      assert relinked.status == feature.status
      assert relinked.title == feature.title
      assert relinked.state_version == feature.state_version

      assert {:error, :not_linked} =
               Features.fetch_by_specification(project.id, first.specification.id)

      assert {:ok, resolved} =
               Features.fetch_by_specification(project.id, second.specification.id)

      assert resolved.id == feature.id
    end

    test "the owner clears a link and the read reports a clear not-linked result", %{
      project: project,
      workspace: workspace,
      feature: feature,
      owner: owner
    } do
      current = specification(workspace, project)

      {:ok, linked} =
        Features.link_specification(
          workspace,
          project.id,
          owner,
          feature,
          current.specification.id
        )

      assert {:ok, cleared} = Features.unlink_specification(project.id, owner, linked)
      assert is_nil(cleared.specification_id)

      assert {:error, :not_linked} =
               Features.fetch_by_specification(project.id, current.specification.id)
    end
  end

  describe "at most one feature per specification" do
    test "linking a second feature to an already-linked specification is rejected, and the first feature's link is unchanged",
         %{project: project, workspace: workspace, feature: first_feature, owner: owner} do
      second_feature = DeliveryFixtures.feature_fixture(project, %{id: owner.account_id})
      current = specification(workspace, project)

      assert {:ok, _linked} =
               Features.link_specification(
                 workspace,
                 project.id,
                 owner,
                 first_feature,
                 current.specification.id
               )

      assert {:error, :already_linked} =
               Features.link_specification(
                 workspace,
                 project.id,
                 owner,
                 second_feature,
                 current.specification.id
               )

      assert {:ok, resolved} =
               Features.fetch_by_specification(project.id, current.specification.id)

      assert resolved.id == first_feature.id

      unchanged = Repo.get!(Feature, second_feature.id)
      assert is_nil(unchanged.specification_id)
    end
  end

  describe "fetch_by_specification/2" do
    test "returns a clear not-linked result, never an error or a guess, when no link exists", %{
      project: project
    } do
      assert {:error, :not_linked} =
               Features.fetch_by_specification(project.id, Ecto.UUID.generate())
    end

    test "never raises for a malformed project or specification identity" do
      assert {:error, :not_linked} = Features.fetch_by_specification("not-a-uuid", "not-a-uuid")
    end
  end

  describe "authorization" do
    test "a non-owner participant is refused link_specification/5, and the feature is unchanged",
         %{project: project, workspace: workspace, feature: feature, participant: participant} do
      current = specification(workspace, project)

      assert {:error, :unauthorized} =
               Features.link_specification(
                 workspace,
                 project.id,
                 participant,
                 feature,
                 current.specification.id
               )

      unchanged = Repo.get!(Feature, feature.id)
      assert is_nil(unchanged.specification_id)
    end

    test "a non-owner participant is refused unlink_specification/3, and the feature is unchanged",
         %{
           project: project,
           workspace: workspace,
           feature: feature,
           owner: owner,
           participant: participant
         } do
      current = specification(workspace, project)

      {:ok, linked} =
        Features.link_specification(
          workspace,
          project.id,
          owner,
          feature,
          current.specification.id
        )

      assert {:error, :unauthorized} =
               Features.unlink_specification(project.id, participant, linked)

      unchanged = Repo.get!(Feature, feature.id)
      assert unchanged.specification_id == current.specification.id
    end
  end

  describe "device-adapter value shape" do
    test "round trips a linked feature through to_value/1 and from_value/1", %{
      project: project,
      workspace: workspace,
      feature: feature,
      owner: owner
    } do
      current = specification(workspace, project)

      {:ok, linked} =
        Features.link_specification(
          workspace,
          project.id,
          owner,
          feature,
          current.specification.id
        )

      value = Feature.to_value(linked)
      assert value["specification_id"] == current.specification.id

      assert {:ok, restored} = Feature.from_value(value)
      assert restored.specification_id == current.specification.id
      assert Feature.to_value(restored) == value
    end

    test "restores specification_id: nil from a value serialized before this migration existed",
         %{feature: feature} do
      value = feature |> Feature.to_value() |> Map.delete("specification_id")

      refute Map.has_key?(value, "specification_id")
      assert {:ok, restored} = Feature.from_value(value)
      assert is_nil(restored.specification_id)
    end
  end
end
