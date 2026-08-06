defmodule SddOrchestrator.Worker.BoundaryTest do
  @moduledoc """
  Task 2 proof: a cheap, deliberate architectural-boundary check. The
  worker's ongoing runtime (everything under `lib/sdd_orchestrator/worker/`
  and the `mix worker.start` task) must never reference the database repo or
  a control-plane context module — even indirectly through new code — so a
  genuinely remote worker never needs them. `mix worker.pair` is exempt: it
  is the one-shot, explicitly local, database-backed pairing step.
  """

  use ExUnit.Case, async: true

  @forbidden [
    "SddOrchestrator.Repo",
    "Ecto.Repo",
    "SddOrchestrator.Devices",
    "SddOrchestrator.Projects",
    "SddOrchestrator.Delivery",
    "SddOrchestrator.Accounts",
    "SddOrchestrator.Portability"
  ]

  @runtime_paths Path.wildcard("lib/sdd_orchestrator/worker/**/*.ex") ++
                   ["lib/mix/tasks/worker.start.ex"]

  test "the worker runtime path never references a database repo or control-plane context" do
    refute Enum.empty?(@runtime_paths)

    for path <- @runtime_paths do
      source = File.read!(path)

      for needle <- @forbidden do
        refute source =~ needle, "#{path} unexpectedly references #{needle}"
      end
    end
  end

  test "mix worker.pair is exempt and is not part of the scanned runtime path" do
    refute "lib/mix/tasks/worker.pair.ex" in @runtime_paths
    assert File.exists?("lib/mix/tasks/worker.pair.ex")
  end
end
