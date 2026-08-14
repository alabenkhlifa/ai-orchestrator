defmodule SddOrchestrator.ProjectAssistant.ProgressiveDiscoveryPlannerTest do
  @moduledoc """
  specs/12-project-assistant Task 5 focused proof: the pure planning function
  behind bounded progressive source discovery (AC-13) — it expands only what
  budget allows, halts with a non-empty frontier when budget runs out rather
  than requesting everything, and halts complete once nothing remains.
  """
  use ExUnit.Case, async: true

  alias SddOrchestrator.ProjectAssistant.ProgressiveDiscoveryPlanner, as: Planner

  describe "an empty repository" do
    test "halts complete on the very first step when the root has no subdirectories" do
      budget = Planner.new(10, 100)
      exploration = Planner.start()

      assert {:list, "."} = Planner.next(budget, exploration)

      exploration = Planner.record(exploration, ".", [], 0)

      assert Planner.next(budget, exploration) == :halt_complete
    end
  end

  describe "a repository with nested directories" do
    test "expands the frontier breadth-first from discovered directories" do
      budget = Planner.new(10, 1_000)
      exploration = Planner.start()

      assert {:list, "."} = Planner.next(budget, exploration)
      exploration = Planner.record(exploration, ".", ["src", "test"], 3)

      assert {:list, next_path} = Planner.next(budget, exploration)
      assert next_path in ["src", "test"]

      exploration = Planner.record(exploration, next_path, [], 2)
      remaining = List.first(["src", "test"] -- [next_path])

      assert Planner.next(budget, exploration) == {:list, remaining}

      exploration = Planner.record(exploration, remaining, [], 1)
      assert Planner.next(budget, exploration) == :halt_complete
    end

    test "never revisits an already-listed directory even if discovered again" do
      exploration = Planner.start()

      exploration = Planner.record(exploration, ".", ["src"], 1)
      # "src" is discovered again from a sibling listing before it is visited.
      exploration = Planner.record(exploration, "lib", ["src"], 1)

      assert exploration.frontier == ["src"]
    end
  end

  describe "a large repository" do
    test "halts on call budget with a non-empty frontier — bounded, not a full walk" do
      budget = Planner.new(1, 1_000)
      exploration = Planner.start()

      assert {:list, "."} = Planner.next(budget, exploration)
      exploration = Planner.record(exploration, ".", ["a", "b", "c"], 3)

      assert Planner.next(budget, exploration) == :halt_budget_exhausted
      refute exploration.frontier == []
    end

    test "halts on entry budget with a non-empty frontier — bounded, not a full walk" do
      budget = Planner.new(100, 5)
      exploration = Planner.start()

      exploration = Planner.record(exploration, ".", ["a", "b"], 10)

      assert Planner.next(budget, exploration) == :halt_budget_exhausted
      refute exploration.frontier == []
    end
  end
end
