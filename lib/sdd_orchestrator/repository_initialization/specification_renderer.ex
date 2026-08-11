defmodule SddOrchestrator.RepositoryInitialization.SpecificationRenderer do
  @moduledoc """
  Renders one confirmed `RepositoryInitialization.Plan` into the complete
  three-document specification set (`requirements`, `design`, `tasks`) that
  `Handoff` (Task 6, AC-13) stores as the project's authoritative first
  revision.

  Pure and read-only: no filesystem access, no I/O, no path resolution. Every
  plan field is carried through verbatim, never paraphrased or summarized —
  matching `SpecificationDocuments`'s own moduledoc that a document is
  untrusted plain text with "no path resolution, interpolation, rendering, or
  command execution" downstream. The rendered `design` document reflects
  only what Task 4/5 actually built (`Skeleton.content/0`'s fixed
  `structure`/`git_behavior` and the plan's own `kit_choice`) — nothing here
  invents architecture beyond that, the same "smallest runnable and
  verifiable foundation" discipline `Skeleton` and Task 3's plan review
  already established for this slice.

  Never emits a real absolute filesystem path: `Plan` itself never carries
  one (`target_reference` is always an opaque token), and this module
  introduces none.
  """

  alias SddOrchestrator.RepositoryInitialization.{Plan, Skeleton}

  @type documents :: %{requirements: String.t(), design: String.t(), tasks: String.t()}

  @doc "Renders `plan` into the complete requirements/design/tasks document set."
  @spec render(Plan.t()) :: documents()
  def render(%Plan{} = plan) do
    %{
      requirements: render_requirements(plan),
      design: render_design(plan),
      tasks: render_tasks()
    }
  end

  defp render_requirements(plan) do
    """
    # Requirements

    Captured during empty-repository initialization, from the plan's own
    guided answers.

    ## Purpose

    #{text_or_placeholder(plan.purpose)}

    ## Users

    #{text_or_placeholder(plan.users)}

    ## First outcome

    #{text_or_placeholder(plan.first_outcome)}

    ## Constraints

    #{text_or_placeholder(plan.constraints)}
    """
  end

  defp render_design(plan) do
    """
    # Design

    ## Technical foundation

    #{render_technical_foundation(plan.technical_foundation)}

    ## Permanent SDD kit

    Kit choice: #{plan.kit_choice}

    ## Repository structure

    #{render_structure(Skeleton.content()["structure"])}

    ## Git behavior

    #{render_git_behavior(Skeleton.content()["git_behavior"])}
    """
  end

  defp render_tasks do
    """
    # Tasks

    No implementation tasks are defined yet from this initialization.

    Use the `add-spec` workflow to define the first real feature
    specification and its own implementation tasks.
    """
  end

  defp text_or_placeholder(nil), do: "Not recorded."

  defp text_or_placeholder(value) when is_binary(value) do
    case String.trim(value) do
      "" -> "Not recorded."
      trimmed -> trimmed
    end
  end

  defp render_technical_foundation(foundation) when map_size(foundation) == 0 do
    "Not recorded."
  end

  defp render_technical_foundation(foundation) do
    case Map.keys(foundation) do
      ["summary"] -> text_or_placeholder(foundation["summary"])
      _structured -> render_structured_foundation(foundation)
    end
  end

  defp render_structured_foundation(foundation) do
    foundation
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map_join("\n", fn {key, value} -> "- #{key}: #{render_foundation_value(value)}" end)
  end

  defp render_foundation_value(value) when is_binary(value), do: value
  defp render_foundation_value(value), do: inspect(value)

  defp render_structure(entries) do
    Enum.map_join(entries, "\n", fn entry -> "- #{entry["path"]} (#{entry["category"]})" end)
  end

  defp render_git_behavior(git_behavior) do
    "- Initial branch: #{git_behavior["initial_branch"]}\n" <>
      "- Hooks: #{git_behavior["hooks"]}\n" <>
      "- First commit message: #{git_behavior["first_commit_message"]}"
  end
end
