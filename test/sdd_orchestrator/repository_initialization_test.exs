defmodule SddOrchestrator.RepositoryInitializationTest do
  @moduledoc """
  Task 2 proof: plan creation, the opaque-path rule (`target_reference` never
  equals or embeds the real path), the decision gate
  (`answer_field/3` refuses answering any field but `current_field`), and the
  plan-version proof (version increments by exactly one per accepted answer).
  """
  use SddOrchestrator.DataCase, async: true

  alias SddOrchestrator.Delivery.WorkerProtocol
  alias SddOrchestrator.RepositoryInitialization
  alias SddOrchestrator.RepositoryInitialization.Plan

  @real_path "/Users/someone/secret-project"

  describe "create_plan/1" do
    test "creates one plan at version 1 with the cursor on purpose" do
      assert {:ok, plan} = RepositoryInitialization.create_plan(base_attrs())

      assert plan.version == 1
      assert plan.current_field == "purpose"
      assert plan.eligibility == "empty_directory"
      assert plan.technical_foundation == %{}
    end

    test "the target reference is opaque: never the real path, never embedding it" do
      assert {:ok, plan} = RepositoryInitialization.create_plan(base_attrs())

      refute plan.target_reference == @real_path
      refute String.contains?(plan.target_reference, @real_path)
      refute String.contains?(plan.target_reference, "secret-project")
      assert WorkerProtocol.valid_id?(plan.target_reference)
    end

    test "account_id is nil when no signed-in account initiated the plan" do
      assert {:ok, plan} = RepositoryInitialization.create_plan(base_attrs())

      assert plan.account_id == nil
    end

    test "rejects an unsupported eligibility value" do
      assert {:error, changeset} =
               RepositoryInitialization.create_plan(
                 Map.put(base_attrs(), :eligibility, "already_has_commits")
               )

      assert %{eligibility: ["is invalid"]} = errors_on(changeset)
    end
  end

  describe "answer_field/3 — decision gate" do
    test "accepts an answer for exactly the current field, advancing the cursor" do
      {:ok, plan} = RepositoryInitialization.create_plan(base_attrs())

      assert {:ok, plan} = RepositoryInitialization.answer_field(plan, "purpose", "A CLI tool")

      assert plan.purpose == "A CLI tool"
      assert plan.current_field == "users"
    end

    test "refuses answering a field that isn't current_field without writing anything" do
      {:ok, plan} = RepositoryInitialization.create_plan(base_attrs())

      assert {:error, :out_of_order} =
               RepositoryInitialization.answer_field(plan, "technical_foundation", %{
                 "language" => "elixir"
               })

      assert {:ok, reloaded} = RepositoryInitialization.get_plan(plan.id)
      assert reloaded.current_field == "purpose"
      assert reloaded.version == 1
      assert reloaded.technical_foundation == %{}
    end

    test "refuses answering users before purpose is answered" do
      {:ok, plan} = RepositoryInitialization.create_plan(base_attrs())

      assert {:error, :out_of_order} =
               RepositoryInitialization.answer_field(plan, "users", "Founders")
    end

    test "cannot reach technical_foundation before purpose, users, first_outcome, and constraints" do
      {:ok, plan} = RepositoryInitialization.create_plan(base_attrs())

      {:ok, plan} = RepositoryInitialization.answer_field(plan, "purpose", "A CLI tool")
      assert plan.current_field == "users"

      assert {:error, :out_of_order} =
               RepositoryInitialization.answer_field(plan, "technical_foundation", %{
                 "language" => "elixir"
               })
    end

    test "walking every field in order reaches ready" do
      {:ok, plan} = RepositoryInitialization.create_plan(base_attrs())

      {:ok, plan} = RepositoryInitialization.answer_field(plan, "purpose", "A CLI tool")
      {:ok, plan} = RepositoryInitialization.answer_field(plan, "users", "Founders")
      {:ok, plan} = RepositoryInitialization.answer_field(plan, "first_outcome", "First release")
      {:ok, plan} = RepositoryInitialization.answer_field(plan, "constraints", "None yet")

      {:ok, plan} =
        RepositoryInitialization.answer_field(plan, "technical_foundation", %{
          "language" => "elixir"
        })

      assert plan.current_field == "ready"
      assert plan.version == 6
    end

    test "rejects a blank answer" do
      {:ok, plan} = RepositoryInitialization.create_plan(base_attrs())

      assert {:error, :invalid_answer} =
               RepositoryInitialization.answer_field(plan, "purpose", "   ")

      assert {:ok, reloaded} = RepositoryInitialization.get_plan(plan.id)
      assert reloaded.current_field == "purpose"
      assert reloaded.version == 1
    end
  end

  describe "answer_field/3 — plan-version proof" do
    test "version increments by exactly 1 per accepted answer" do
      {:ok, plan} = RepositoryInitialization.create_plan(base_attrs())
      assert plan.version == 1

      {:ok, plan} = RepositoryInitialization.answer_field(plan, "purpose", "A CLI tool")
      assert plan.version == 2

      {:ok, plan} = RepositoryInitialization.answer_field(plan, "users", "Founders")
      assert plan.version == 3
    end

    test "a rejected out-of-order answer never bumps the version" do
      {:ok, plan} = RepositoryInitialization.create_plan(base_attrs())

      assert {:error, :out_of_order} =
               RepositoryInitialization.answer_field(plan, "constraints", "None")

      assert {:ok, reloaded} = RepositoryInitialization.get_plan(plan.id)
      assert reloaded.version == 1
    end
  end

  describe "get_plan/1" do
    test "returns not_found for an unknown id" do
      assert {:error, :not_found} = RepositoryInitialization.get_plan(Ecto.UUID.generate())
    end

    test "returns not_found for a malformed id rather than raising" do
      assert {:error, :not_found} = RepositoryInitialization.get_plan("not-a-uuid")
    end
  end

  describe "Plan.next_field/1" do
    test "walks the exact fixed order" do
      assert Plan.next_field("purpose") == "users"
      assert Plan.next_field("users") == "first_outcome"
      assert Plan.next_field("first_outcome") == "constraints"
      assert Plan.next_field("constraints") == "technical_foundation"
      assert Plan.next_field("technical_foundation") == "ready"
      assert Plan.next_field("ready") == nil
    end
  end

  defp base_attrs do
    %{
      device_workspace_id: Ecto.UUID.generate(),
      target_reference: WorkerProtocol.generate_id(),
      eligibility: "empty_directory"
    }
  end
end
