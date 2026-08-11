defmodule SddOrchestrator.RepositoryInitialization.SpecificationRendererTest do
  @moduledoc """
  Task 6 proof: `SpecificationRenderer.render/1` carries every plan field
  through verbatim, renders both `technical_foundation` shapes without
  crashing, reflects the plan's `kit_choice` and the fixed `Skeleton`
  content, states plainly that no implementation tasks are defined yet, and
  never leaks a real absolute filesystem path.
  """
  use ExUnit.Case, async: true

  alias SddOrchestrator.RepositoryInitialization.{Plan, Skeleton, SpecificationRenderer}

  describe "requirements document" do
    test "carries purpose, users, first_outcome, and constraints verbatim" do
      plan = plan_fixture()

      documents = SpecificationRenderer.render(plan)

      assert documents.requirements =~ plan.purpose
      assert documents.requirements =~ plan.users
      assert documents.requirements =~ plan.first_outcome
      assert documents.requirements =~ plan.constraints
    end

    test "renders a placeholder for a blank or missing field" do
      plan = plan_fixture(%{constraints: nil})

      documents = SpecificationRenderer.render(plan)

      assert documents.requirements =~ "Not recorded."
    end
  end

  describe "design document" do
    test "renders a free-text technical_foundation (\"summary\" shape) readably" do
      plan = plan_fixture(%{technical_foundation: %{"summary" => "Elixir + Phoenix"}})

      documents = SpecificationRenderer.render(plan)

      assert documents.design =~ "Elixir + Phoenix"
    end

    test "renders a structured technical_foundation (arbitrary key/value shape) readably" do
      plan =
        plan_fixture(%{
          technical_foundation: %{"language" => "elixir", "framework" => "phoenix"}
        })

      documents = SpecificationRenderer.render(plan)

      assert documents.design =~ "language: elixir"
      assert documents.design =~ "framework: phoenix"
    end

    test "renders a non-string structured value without crashing" do
      plan = plan_fixture(%{technical_foundation: %{"max_users" => 10, "beta" => true}})

      documents = SpecificationRenderer.render(plan)

      assert documents.design =~ "max_users: 10"
      assert documents.design =~ "beta: true"
    end

    test "renders an empty technical_foundation without crashing" do
      plan = plan_fixture(%{technical_foundation: %{}})

      documents = SpecificationRenderer.render(plan)

      assert documents.design =~ "Not recorded."
    end

    test "reflects an included kit choice" do
      plan = plan_fixture(%{kit_choice: "included"})

      documents = SpecificationRenderer.render(plan)

      assert documents.design =~ "Kit choice: included"
    end

    test "reflects a declined kit choice" do
      plan = plan_fixture(%{kit_choice: "declined"})

      documents = SpecificationRenderer.render(plan)

      assert documents.design =~ "Kit choice: declined"
    end

    test "reflects the fixed skeleton structure and Git behavior" do
      plan = plan_fixture()
      skeleton = Skeleton.content()

      documents = SpecificationRenderer.render(plan)

      for entry <- skeleton["structure"] do
        assert documents.design =~ entry["path"]
      end

      assert documents.design =~ skeleton["git_behavior"]["initial_branch"]
      assert documents.design =~ skeleton["git_behavior"]["hooks"]
      assert documents.design =~ skeleton["git_behavior"]["first_commit_message"]
    end
  end

  describe "tasks document" do
    test "states that no implementation tasks are defined yet and points at add-spec" do
      documents = SpecificationRenderer.render(plan_fixture())

      assert documents.tasks =~ "No implementation tasks are defined yet"
      assert documents.tasks =~ "add-spec"
    end
  end

  describe "no real path leaks" do
    test "none of the three documents contains the real current working directory" do
      documents = SpecificationRenderer.render(plan_fixture())
      cwd = File.cwd!()

      refute documents.requirements =~ cwd
      refute documents.design =~ cwd
      refute documents.tasks =~ cwd
    end

    test "none of the three documents contains an absolute path segment" do
      documents = SpecificationRenderer.render(plan_fixture())

      refute Regex.match?(~r{(^|\s)/[A-Za-z0-9_.\-/]*/[A-Za-z0-9_.\-]+}, documents.requirements)
      refute Regex.match?(~r{(^|\s)/[A-Za-z0-9_.\-/]*/[A-Za-z0-9_.\-]+}, documents.design)
      refute Regex.match?(~r{(^|\s)/[A-Za-z0-9_.\-/]*/[A-Za-z0-9_.\-]+}, documents.tasks)
    end
  end

  defp plan_fixture(overrides \\ %{}) do
    struct(
      %Plan{
        purpose: "A CLI tool",
        users: "Founders",
        first_outcome: "First working release",
        constraints: "None yet",
        technical_foundation: %{"summary" => "Elixir + Phoenix"},
        kit_choice: "declined"
      },
      overrides
    )
  end
end
