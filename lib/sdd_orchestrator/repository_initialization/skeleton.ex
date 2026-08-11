defmodule SddOrchestrator.RepositoryInitialization.Skeleton do
  @moduledoc """
  The fixed, deterministic first-plan skeleton content (AC-04).

  There is no mechanism anywhere in this codebase for turning a free-text
  `technical_foundation` answer into a structured file/command/check list,
  and building one is real, risky, new engineering surface that no test in
  this slice exercises against a real coding-agent CLI. Business rules
  already require the first plan to be "the smallest runnable and verifiable
  foundation" — the honest, smallest-possible first pass is a small fixed
  constant: no assumed language tooling, no invented commands, no invented
  checks. A later slice can add real per-stack scaffolding from
  `technical_foundation`; that is explicitly out of this task's scope.

  This is a constant, not user data — it is never stored per-plan in the
  database. It is computed fresh wherever it is needed: rendering the review
  step and binding the confirmation digest
  (`RepositoryInitialization.confirmation_snapshot/1`).
  """

  @content %{
    "structure" => [%{"path" => "README.md", "category" => "documentation"}],
    "commands" => [],
    "checks" => [],
    "git_behavior" => %{
      "initial_branch" => "main",
      "hooks" => "disabled",
      "first_commit_message" => "Initial commit"
    }
  }

  @doc "The fixed first-plan skeleton content: structure, commands, checks, and Git behavior."
  @spec content() :: map()
  def content, do: @content
end
