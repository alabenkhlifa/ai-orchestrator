defmodule SddOrchestrator.Privacy.ProjectAssistantProcessingInventoryTest do
  @moduledoc """
  specs/12-project-assistant Task 9 focused proof: the mechanically
  validated field-purpose and access inventory (AC-19, AC-20's "no
  unclassified processing" guarantee, mirroring
  `SddOrchestrator.Privacy.DeliveryProcessingInventory`'s own proof shape).
  """
  use ExUnit.Case, async: true

  alias SddOrchestrator.Privacy.ProjectAssistantProcessingInventory, as: Inventory

  test "every inventoried record validates against the fixed classification vocabulary" do
    assert Inventory.validate_all() == :ok
  end

  test "no schema field is missing a classification" do
    assert Inventory.missing_fields() == %{}
  end

  test "no classification names a field its schema no longer declares" do
    assert Inventory.unknown_fields() == %{}
  end

  test "completeness/0 reports :ok" do
    assert Inventory.completeness() == :ok
  end

  test "every governed schema is classified" do
    schemas = Inventory.schemas()

    assert Map.keys(schemas) |> Enum.sort() == [
             :assistant_boundary_confirmation,
             :project_assistant_citation,
             :project_assistant_conversation,
             :project_assistant_turn,
             :project_context_projection
           ]
  end

  test "no participant-private entity uses the shared current_participants recipient" do
    private_entities = [
      :project_assistant_conversation,
      :project_assistant_turn,
      :project_assistant_citation,
      :assistant_boundary_confirmation
    ]

    for record <- Inventory.records(), record.entity in private_entities do
      refute record.recipient_category == :current_participants,
             "#{record.entity}.#{record.field} must not use the shared current_participants recipient"
    end
  end

  test "only question_text and answer_text cross to the model provider" do
    provider_fields =
      Inventory.records()
      |> Enum.filter(&(&1.recipient_category == :model_provider))
      |> Enum.map(&{&1.entity, &1.field})
      |> Enum.sort()

    assert provider_fields == [
             project_assistant_turn: :answer_text,
             project_assistant_turn: :question_text
           ]
  end

  test "every field is owned by this specification's own lifecycle" do
    assert Enum.all?(
             Inventory.records(),
             &(&1.lifecycle_owner == :specs_12_project_assistant_lifecycle)
           )
  end
end
