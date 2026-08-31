defmodule SddOrchestrator.Delivery.GuidedRequirementsTest do
  @moduledoc """
  Proof of the four-part requirements document shape (Task 2 of
  specs/41-feature-delivery-from-the-ui, AC-02).

  The form and the document have to mean the same thing in both directions, and
  the document is not the form's alone: a run writes its own sections into the
  same requirements, and reading it back must leave them where they are.
  """
  use ExUnit.Case, async: true

  alias SddOrchestrator.Delivery.{GuidedRequirements, Readiness}

  @filled %{
    "outcome" => "A person can search their features by title.",
    "users" => "Anyone on the project.",
    "rules" => "An empty search shows everything.\n\nNo result is ever hidden.",
    "done" => "Typing a title finds the feature."
  }

  test "the parts are the ones readiness judges, in the same order" do
    assert GuidedRequirements.structure() == Readiness.guided_structure()
    assert GuidedRequirements.keys() == ["outcome", "users", "rules", "done"]
  end

  test "the empty document carries every heading and nothing under any of them" do
    document = GuidedRequirements.empty()

    for part <- Readiness.guided_structure() do
      assert String.contains?(document, "## " <> part.label <> "\n")
    end

    assert GuidedRequirements.parse(document) == %{
             "outcome" => "",
             "users" => "",
             "rules" => "",
             "done" => ""
           }
  end

  test "rendering and parsing round-trip the four bodies" do
    assert GuidedRequirements.parse(GuidedRequirements.render(@filled)) == @filled
  end

  test "a body keeps its own blank lines and loses only the surrounding whitespace" do
    parsed =
      %{@filled | "outcome" => "  Trailing space and lines.\n\n"}
      |> GuidedRequirements.render()
      |> GuidedRequirements.parse()

    assert parsed["outcome"] == "Trailing space and lines."
    assert parsed["rules"] == @filled["rules"]
  end

  test "a heading present with an empty body parses to an empty string" do
    parsed = GuidedRequirements.parse(GuidedRequirements.render(%{"outcome" => "Only this."}))

    assert parsed["outcome"] == "Only this."
    assert parsed["users"] == ""
    assert parsed["rules"] == ""
    assert parsed["done"] == ""
  end

  test "text the four parts do not name is ignored rather than turned into a part" do
    document =
      GuidedRequirements.render(@filled) <>
        "\n## Decision: Search filters\n\nQuestion: which?\n\nAnswer: by title.\n"

    parsed = GuidedRequirements.parse(document)

    assert Enum.sort(Map.keys(parsed)) == Enum.sort(GuidedRequirements.keys())
    assert parsed == @filled
  end

  test "a document with none of the headings answers four empty bodies" do
    assert GuidedRequirements.parse("Some notes nobody wrote under a heading.") == %{
             "outcome" => "",
             "users" => "",
             "rules" => "",
             "done" => ""
           }
  end
end
