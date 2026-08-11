defmodule SddOrchestrator.RepositoryInitializationTest do
  @moduledoc """
  Task 2 proof: plan creation, the opaque-path rule (`target_reference` never
  equals or embeds the real path), the decision gate
  (`answer_field/3` refuses answering any field but `current_field`), and the
  plan-version proof (version increments by exactly one per accepted answer).

  Task 3 proof: `default_kit/0`'s newest-version selection and empty-catalog
  refusal, `set_kit_choice/2`'s include/decline behavior and its
  changed-input invalidation of a prior confirmation,
  `disclose_processing_boundary/1`, `confirmation_snapshot/1`'s exact bound
  shape, and `confirm_plan/2`'s success, `:plan_changed`, and
  `:disclosure_required` refusals plus the confirmation-digest binding proof.
  """
  use SddOrchestrator.DataCase, async: true

  import SddOrchestrator.RepositoryKitFixtures

  alias SddOrchestrator.Delivery.WorkerProtocol
  alias SddOrchestrator.RepositoryInitialization
  alias SddOrchestrator.RepositoryInitialization.{Plan, Skeleton}

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

  describe "default_kit/0" do
    test "returns error when the catalog is empty" do
      assert {:error, :no_kit_available} = RepositoryInitialization.default_kit()
    end

    test "picks the newest version when multiple packages exist" do
      # Distinct file content per package: the catalog's digest uniqueness
      # constraint is keyed on file content, not version, so identical
      # default fixture files across versions would collide.
      publish_package_fixture(
        %{version: "1.0.0", scripts: []},
        [%{path: "a.md", content: "v1.0.0", executable: false}]
      )

      newest =
        publish_package_fixture(
          %{version: "2.1.0", scripts: []},
          [%{path: "a.md", content: "v2.1.0", executable: false}]
        )

      publish_package_fixture(
        %{version: "1.5.0", scripts: []},
        [%{path: "a.md", content: "v1.5.0", executable: false}]
      )

      assert {:ok, package} = RepositoryInitialization.default_kit()
      assert package.id == newest.id
      assert package.version == "2.1.0"
    end
  end

  describe "set_kit_choice/2" do
    test "refuses unless the plan is ready" do
      {:ok, plan} = RepositoryInitialization.create_plan(base_attrs())

      assert {:error, :plan_not_ready} = RepositoryInitialization.set_kit_choice(plan, "included")
    end

    test "including with no kit in the catalog refuses :no_kit_available" do
      plan = ready_plan_fixture()

      assert {:error, :no_kit_available} =
               RepositoryInitialization.set_kit_choice(plan, "included")
    end

    test "including snapshots the default kit's id and digest" do
      package = publish_package_fixture()
      plan = ready_plan_fixture()

      assert {:ok, plan} = RepositoryInitialization.set_kit_choice(plan, "included")

      assert plan.kit_choice == "included"
      assert plan.kit_package_id == package.id
      assert plan.kit_package_digest == package.digest
    end

    test "declining clears the kit package id and digest" do
      publish_package_fixture()
      plan = ready_plan_fixture()
      {:ok, plan} = RepositoryInitialization.set_kit_choice(plan, "included")

      assert {:ok, plan} = RepositoryInitialization.set_kit_choice(plan, "declined")

      assert plan.kit_choice == "declined"
      assert plan.kit_package_id == nil
      assert plan.kit_package_digest == nil
    end

    test "rejects an unsupported choice value" do
      plan = ready_plan_fixture()

      assert {:error, :invalid_kit_choice} =
               RepositoryInitialization.set_kit_choice(plan, "maybe")
    end

    test "changing the kit choice clears a prior confirmation (changed-input invalidation)" do
      publish_package_fixture()
      plan = ready_plan_fixture()
      {:ok, plan} = RepositoryInitialization.set_kit_choice(plan, "included")
      {:ok, plan} = RepositoryInitialization.disclose_processing_boundary(plan)
      {:ok, snapshot} = RepositoryInitialization.confirmation_snapshot(plan)
      {:ok, plan} = RepositoryInitialization.confirm_plan(plan, snapshot)

      assert plan.confirmed_at != nil
      assert plan.confirmation_digest != nil

      assert {:ok, plan} = RepositoryInitialization.set_kit_choice(plan, "declined")

      assert plan.confirmed_at == nil
      assert plan.confirmation_digest == nil
    end
  end

  describe "disclose_processing_boundary/1" do
    test "refuses unless the plan is ready" do
      {:ok, plan} = RepositoryInitialization.create_plan(base_attrs())

      assert {:error, :plan_not_ready} =
               RepositoryInitialization.disclose_processing_boundary(plan)
    end

    test "sets the current disclosure version" do
      plan = ready_plan_fixture()

      assert {:ok, plan} = RepositoryInitialization.disclose_processing_boundary(plan)
      assert plan.disclosure_version == RepositoryInitialization.disclosure_version()
    end

    test "is idempotent when already disclosed at the current version" do
      plan = ready_plan_fixture()
      {:ok, plan} = RepositoryInitialization.disclose_processing_boundary(plan)

      assert {:ok, plan_again} = RepositoryInitialization.disclose_processing_boundary(plan)
      assert plan_again.disclosure_version == plan.disclosure_version
    end
  end

  describe "confirmation_snapshot/1" do
    test "refuses unless the plan is ready" do
      {:ok, plan} = RepositoryInitialization.create_plan(base_attrs())

      assert {:error, :plan_not_ready} = RepositoryInitialization.confirmation_snapshot(plan)
    end

    test "returns the exact bound-field shape" do
      publish_package_fixture()
      plan = ready_plan_fixture()
      {:ok, plan} = RepositoryInitialization.set_kit_choice(plan, "included")
      {:ok, plan} = RepositoryInitialization.disclose_processing_boundary(plan)

      assert {:ok, snapshot} = RepositoryInitialization.confirmation_snapshot(plan)

      assert snapshot == %{
               "version" => plan.version,
               "target_reference" => plan.target_reference,
               "technical_foundation" => plan.technical_foundation,
               "kit_choice" => "included",
               "kit_package_digest" => plan.kit_package_digest,
               "commands" => Skeleton.content()["commands"],
               "checks" => Skeleton.content()["checks"],
               "disclosure_version" => RepositoryInitialization.disclosure_version()
             }
    end
  end

  describe "confirm_plan/2" do
    test "succeeds with a matching snapshot" do
      plan = ready_plan_fixture()
      {:ok, plan} = RepositoryInitialization.disclose_processing_boundary(plan)
      {:ok, snapshot} = RepositoryInitialization.confirmation_snapshot(plan)

      assert {:ok, confirmed} = RepositoryInitialization.confirm_plan(plan, snapshot)

      assert confirmed.confirmed_at != nil
      assert confirmed.confirmation_digest != nil
      assert String.match?(confirmed.confirmation_digest, ~r/\A[0-9a-f]{64}\z/)
    end

    test "refuses :disclosure_required before disclosure" do
      plan = ready_plan_fixture()
      {:ok, snapshot} = RepositoryInitialization.confirmation_snapshot(plan)

      assert {:error, :disclosure_required} =
               RepositoryInitialization.confirm_plan(plan, snapshot)
    end

    test "refuses :plan_changed with a stale snapshot (changed-input invalidation)" do
      publish_package_fixture()
      plan = ready_plan_fixture()
      {:ok, plan} = RepositoryInitialization.disclose_processing_boundary(plan)
      {:ok, stale_snapshot} = RepositoryInitialization.confirmation_snapshot(plan)

      {:ok, _mutated} = RepositoryInitialization.set_kit_choice(plan, "included")

      assert {:error, :plan_changed} = RepositoryInitialization.confirm_plan(plan, stale_snapshot)
    end

    test "refuses :plan_not_ready when the plan hasn't reached ready" do
      {:ok, plan} = RepositoryInitialization.create_plan(base_attrs())

      assert {:error, :plan_not_ready} = RepositoryInitialization.confirm_plan(plan, %{})
    end
  end

  describe "confirmation digest binding" do
    test "is stable for identical bound content and changes when a bound field changes" do
      shared_target = WorkerProtocol.generate_id()

      plan_a = ready_plan_fixture(%{target_reference: shared_target})
      {:ok, plan_a} = RepositoryInitialization.disclose_processing_boundary(plan_a)
      {:ok, snapshot_a} = RepositoryInitialization.confirmation_snapshot(plan_a)
      {:ok, confirmed_a} = RepositoryInitialization.confirm_plan(plan_a, snapshot_a)

      plan_b = ready_plan_fixture(%{target_reference: shared_target})
      {:ok, plan_b} = RepositoryInitialization.disclose_processing_boundary(plan_b)
      {:ok, snapshot_b} = RepositoryInitialization.confirmation_snapshot(plan_b)
      {:ok, confirmed_b} = RepositoryInitialization.confirm_plan(plan_b, snapshot_b)

      assert confirmed_a.confirmation_digest == confirmed_b.confirmation_digest

      publish_package_fixture()
      {:ok, plan_c} = RepositoryInitialization.set_kit_choice(plan_b, "included")
      {:ok, plan_c} = RepositoryInitialization.disclose_processing_boundary(plan_c)
      {:ok, snapshot_c} = RepositoryInitialization.confirmation_snapshot(plan_c)
      {:ok, confirmed_c} = RepositoryInitialization.confirm_plan(plan_c, snapshot_c)

      refute confirmed_c.confirmation_digest == confirmed_a.confirmation_digest
    end
  end

  defp base_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        device_workspace_id: Ecto.UUID.generate(),
        target_reference: WorkerProtocol.generate_id(),
        eligibility: "empty_directory"
      },
      overrides
    )
  end

  # Walks a freshly created plan through every answerable field to "ready".
  defp ready_plan_fixture(attrs_overrides \\ %{}) do
    {:ok, plan} = RepositoryInitialization.create_plan(base_attrs(attrs_overrides))

    {:ok, plan} = RepositoryInitialization.answer_field(plan, "purpose", "A CLI tool")
    {:ok, plan} = RepositoryInitialization.answer_field(plan, "users", "Founders")
    {:ok, plan} = RepositoryInitialization.answer_field(plan, "first_outcome", "First release")
    {:ok, plan} = RepositoryInitialization.answer_field(plan, "constraints", "None yet")

    {:ok, plan} =
      RepositoryInitialization.answer_field(plan, "technical_foundation", %{
        "language" => "elixir"
      })

    plan
  end
end
