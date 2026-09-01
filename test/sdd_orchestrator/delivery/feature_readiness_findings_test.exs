defmodule SddOrchestrator.Delivery.FeatureReadinessFindingsTest do
  @moduledoc """
  Proof for readiness judged from the feature's own specification (Task 3 of
  specs/41-feature-delivery-from-the-ui, AC-03).

  Four properties carry the whole task. Readiness reads the feature's linked
  specification and refuses a feature that has none. A guided part with nothing
  under it blocks without any model being asked. A configured model adds to
  those findings rather than replacing them, and its suggestion is dismissible
  while a structural blocker never is. And a deployment with no guidance model
  still produces a verdict, recorded as such.
  """
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Delivery.{
    Features,
    GuidedRequirements,
    Readiness,
    ReadinessAssessment,
    Suggestions
  }

  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.ReadinessGuidanceDouble
  alias SddOrchestrator.SpecificationFixtures
  alias SddOrchestrator.SpecificationStore

  @written %{
    "outcome" => "A person can find a feature by typing part of its title.",
    "users" => "Anyone on the project, owner or participant.",
    "rules" => "An empty search shows every feature.",
    "done" => "Typing three letters of a title finds that feature."
  }

  setup do
    context = DeliveryFixtures.delivery_project_fixture()

    {:ok, feature} =
      Features.create(context.project.id, context.owner_actor, %{title: "Search features"})

    %{
      context: context,
      authority: context.workspace,
      project: context.project,
      feature: feature,
      owner: context.owner_actor
    }
  end

  describe "structural findings without a model [AC-03]" do
    test "one empty guided part is exactly one blocking finding", ctx do
      write_parts(ctx, Map.delete(@written, "rules"))

      assert {:ok, assessment} = assess(ctx)

      assert [blocker] = ReadinessAssessment.blockers(assessment)
      assert blocker["id"] == "structural-rules"
      assert blocker["category"] == "missing"
      assert blocker["blocking"] == true
      assert ReadinessAssessment.suggestions(assessment) == []
      refute ReadinessAssessment.start_available?(assessment)
    end

    test "every empty part gets its own finding, named in the person's words", ctx do
      assert {:ok, assessment} = assess(ctx)

      blockers = ReadinessAssessment.blockers(assessment)

      assert length(blockers) == length(GuidedRequirements.structure())

      for part <- GuidedRequirements.structure() do
        blocker = Enum.find(blockers, &(&1["id"] == "structural-" <> part.key))

        assert blocker["summary"] =~ part.label
        assert blocker["explanation"] =~ part.hint
      end
    end

    test "a document with all four parts written leaves nothing blocking", ctx do
      write_parts(ctx, @written)

      assert {:ok, assessment} = assess(ctx)

      assert ReadinessAssessment.findings(assessment) == []
      assert ReadinessAssessment.start_available?(assessment)
    end

    test "the verdict is bound to the revision it judged", ctx do
      write_parts(ctx, @written)

      assert {:ok, assessment} = assess(ctx)

      current = current_revision(ctx)

      assert assessment.specification_id == ctx.feature.specification_id
      assert assessment.revision_id == current.revision.id
      assert assessment.revision_digest == current.revision.content_digest
    end
  end

  describe "merging a configured model's findings [AC-03]" do
    setup do
      restore = ReadinessGuidanceDouble.install()
      on_exit(restore)

      :ok
    end

    test "the model's findings apply on top of the structural ones", ctx do
      write_parts(ctx, Map.delete(@written, "rules"))

      ReadinessGuidanceDouble.script(
        {:findings,
         [
           finding("no-error-state", true, "Nothing says what happens when the search fails."),
           finding("tighten-copy", false, "The empty state wording could be clearer.")
         ]}
      )

      assert {:ok, assessment} = assess(ctx)

      assert Enum.map(ReadinessAssessment.blockers(assessment), & &1["id"]) ==
               ~w(structural-rules no-error-state)

      assert Enum.map(ReadinessAssessment.suggestions(assessment), & &1["id"]) ==
               ~w(tighten-copy)
    end

    test "the suggestion is dismissible and the structural blocker is not", ctx do
      write_parts(ctx, Map.delete(@written, "rules"))

      ReadinessGuidanceDouble.script(
        {:findings, [finding("tighten-copy", false, "The empty state wording could be clearer.")]}
      )

      {:ok, assessment} = assess(ctx)

      assert Readiness.dismissible?(assessment, "tighten-copy")
      refute Readiness.dismissible?(assessment, "structural-rules")

      assert {:error, :not_dismissible} =
               Suggestions.dismiss(
                 ctx.project.id,
                 ctx.owner,
                 ctx.feature.id,
                 "structural-rules",
                 assessment.version
               )

      assert {:ok, dismissed} =
               Suggestions.dismiss(
                 ctx.project.id,
                 ctx.owner,
                 ctx.feature.id,
                 "tighten-copy",
                 assessment.version
               )

      assert ReadinessAssessment.suggestions(dismissed) == []
      assert Enum.map(ReadinessAssessment.blockers(dismissed), & &1["id"]) == ~w(structural-rules)
    end

    test "a configured adapter that fails is still an error", ctx do
      write_parts(ctx, @written)
      ReadinessGuidanceDouble.script({:error, :guidance_timeout})

      assert {:error, :guidance_timeout} = assess(ctx)
      assert {:error, :not_found} = Readiness.current(ctx.project.id, ctx.owner, ctx.feature.id)
    end

    test "a model answering nothing is recorded as a configured verdict", ctx do
      write_parts(ctx, @written)

      assert {:ok, assessment} = assess(ctx)

      assert assessment.guidance == "configured"
      assert ReadinessAssessment.guidance_configured?(assessment)
    end
  end

  describe "a deployment with no guidance model [AC-03]" do
    test "the assessment records the fact and keeps its structural findings", ctx do
      assert SddOrchestrator.Delivery.ReadinessGuidance.adapter() ==
               SddOrchestrator.Delivery.ReadinessGuidance.Unconfigured

      write_parts(ctx, Map.delete(@written, "done"))

      assert {:ok, assessment} = assess(ctx)

      assert assessment.guidance == "not_configured"
      refute ReadinessAssessment.guidance_configured?(assessment)
      assert Enum.map(ReadinessAssessment.blockers(assessment), & &1["id"]) == ~w(structural-done)
    end

    test "a fully written feature is ready even though no model judged it", ctx do
      write_parts(ctx, @written)

      assert {:ok, assessment} = assess(ctx)

      assert assessment.guidance == "not_configured"
      assert ReadinessAssessment.start_available?(assessment)
    end
  end

  describe "the feature's own specification and no other [AC-03]" do
    test "a feature with no linked specification is refused", ctx do
      # The state a feature created before this slice is in, and the state the
      # owner's link control can put any feature back into.
      created = DeliveryFixtures.feature_fixture(ctx.project, ctx.context.account)
      {:ok, unlinked} = Features.unlink_specification(ctx.project.id, ctx.owner, created)

      assert unlinked.specification_id == nil

      assert {:error, :no_specification} =
               Readiness.assess(ctx.authority, ctx.owner, %{
                 project: ctx.project,
                 feature: unlinked
               })

      refute Readiness.start_available?(ctx.authority, ctx.project.id, ctx.owner, unlinked.id)
    end

    test "another specification of the project is never judged in its place", ctx do
      {:ok, _other} =
        SpecificationStore.create(
          ctx.authority,
          ctx.project.id,
          SpecificationFixtures.specification_attrs(%{
            title: "Somebody else's feature",
            documents:
              SpecificationFixtures.documents(%{
                requirements: GuidedRequirements.render(@written)
              })
          }),
          actor_ref: "owner"
        )

      assert {:ok, assessment} = assess(ctx)

      assert assessment.specification_id == ctx.feature.specification_id
      assert length(ReadinessAssessment.blockers(assessment)) == 4
    end
  end

  defp assess(ctx),
    do: Readiness.assess(ctx.authority, ctx.owner, %{project: ctx.project, feature: ctx.feature})

  defp current_revision(ctx) do
    {:ok, current} =
      SpecificationStore.get_current(ctx.authority, ctx.project.id, ctx.feature.specification_id)

    current
  end

  # The same store call the feature page's form makes, so readiness judges the
  # document a person would actually have written.
  defp write_parts(ctx, parts) do
    current = current_revision(ctx)

    {:ok, appended} =
      SpecificationStore.append_revision(
        ctx.authority,
        ctx.project.id,
        ctx.feature.specification_id,
        current.revision.id,
        %{
          revision_id: Ecto.UUID.generate(),
          documents: %{
            requirements: GuidedRequirements.render(parts),
            design: current.revision.design_document,
            tasks: current.revision.tasks_document
          }
        }
      )

    appended
  end

  defp finding(id, blocking?, explanation) do
    ReadinessGuidanceDouble.finding(%{
      "id" => id,
      "category" => "ambiguous",
      "blocking" => blocking?,
      "summary" => "A model had something to say.",
      "explanation" => explanation
    })
  end
end
