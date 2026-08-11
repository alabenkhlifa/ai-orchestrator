defmodule SddOrchestrator.RepositoryInitialization.SkeletonTest do
  @moduledoc """
  Task 3 proof: the fixed first-plan skeleton content is exactly what's
  specified — a small, deterministic constant, not generated from
  `technical_foundation` — and is stable across calls.
  """
  use ExUnit.Case, async: true

  alias SddOrchestrator.RepositoryInitialization.Skeleton

  test "content/0 is exactly the fixed, specified shape" do
    assert Skeleton.content() == %{
             "structure" => [%{"path" => "README.md", "category" => "documentation"}],
             "commands" => [],
             "checks" => [],
             "git_behavior" => %{
               "initial_branch" => "main",
               "hooks" => "disabled",
               "first_commit_message" => "Initial commit"
             }
           }
  end

  test "content/0 is stable across calls" do
    assert Skeleton.content() == Skeleton.content()
  end
end
