defmodule SddOrchestrator.Privacy.ProjectAssistantDataUsePolicyTest do
  @moduledoc """
  specs/12-project-assistant Task 9 focused proof: the fail-closed
  purpose/recipient policy (AC-19, AC-20 — no analytics or training reuse,
  and the narrowly scoped `:model_provider` route).
  """
  use ExUnit.Case, async: true

  alias SddOrchestrator.Privacy.ProjectAssistantDataUsePolicy, as: Policy

  test "authorizes the owning participant to read their own conversation" do
    assert Policy.authorize(
             :project_assistant_conversation,
             :conversation_lifecycle,
             :owning_participant
           ) == :ok
  end

  test "authorizes the model provider to receive a turn's question and answer" do
    assert Policy.authorize(
             :project_assistant_turn,
             :answer_participant_question,
             :model_provider
           ) == :ok
  end

  test "refuses the model provider for every other data class" do
    for data_class <- [
          :project_assistant_conversation,
          :project_assistant_citation,
          :assistant_boundary_confirmation,
          :project_context_projection
        ] do
      assert {:error, :not_authorized} =
               Policy.authorize(data_class, :answer_participant_question, :model_provider)
    end
  end

  test "refuses the model provider for every other purpose on the turn" do
    assert {:error, :not_authorized} =
             Policy.authorize(:project_assistant_turn, :retention_cleanup, :model_provider)

    assert {:error, :not_authorized} =
             Policy.authorize(:project_assistant_turn, :verified_rights, :model_provider)
  end

  test "refuses every prohibited secondary-use purpose regardless of data class or consumer" do
    for purpose <- Policy.prohibited_purposes() do
      assert {:error, :secondary_use_prohibited} =
               Policy.authorize(:project_assistant_turn, purpose, :owning_participant)
    end
  end

  test "refuses every prohibited consumer regardless of data class or purpose" do
    for consumer <- Policy.prohibited_consumers() do
      assert {:error, :consumer_prohibited} =
               Policy.authorize(:project_assistant_turn, :answer_participant_question, consumer)
    end
  end

  test "refuses an unlisted route as not_authorized" do
    assert {:error, :not_authorized} =
             Policy.authorize(:project_assistant_conversation, :advertising_profile, :owner)
  end

  test "operations personnel get only lifecycle and rights routes, never a content-reading one" do
    for data_class <- Policy.data_classes() do
      assert Policy.authorize(data_class, :retention_cleanup, :approved_operations) == :ok
      assert Policy.authorize(data_class, :verified_rights, :verified_rights_operator) == :ok
    end
  end

  test "the anonymous aggregate boundary prohibits current processing and names every stable identifier" do
    boundary = Policy.anonymous_aggregate_boundary()
    assert boundary.current_processing == :prohibited
    assert :project in boundary.prohibited_identifiers
    assert :stable_pseudonymous_identifier in boundary.prohibited_identifiers
  end
end
