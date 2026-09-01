defmodule SddOrchestratorWeb.FeatureReadinessSectionTest.ConfiguredGuidance do
  @moduledoc false
  @behaviour SddOrchestrator.Delivery.ReadinessGuidance

  alias SddOrchestrator.Delivery.ReadinessGuidance

  # A stand-in for a working provider, stateless so it answers the same way in
  # the LiveView process as it would in the test process.
  @impl true
  def assess(input) do
    {:ok,
     %{
       "response_version" => ReadinessGuidance.response_version(),
       "revision_id" => input["revision_id"],
       "findings" => [
         %{
           "id" => "no-error-state",
           "category" => "ambiguous",
           "blocking" => true,
           "summary" => "Nothing says what happens when the search fails.",
           "explanation" => "Say what a person sees when the search cannot run."
         },
         %{
           "id" => "tighten-copy",
           "category" => "ambiguous",
           "blocking" => false,
           "summary" => "The empty state wording could be clearer.",
           "explanation" => "Two readers took the empty state to mean different things."
         }
       ]
     }}
  end
end

defmodule SddOrchestratorWeb.FeatureReadinessSectionTest do
  @moduledoc """
  Screen proof for the readiness section (Task 3 of
  specs/41-feature-delivery-from-the-ui, AC-03).

  A person has to be able to press one control and read what this feature still
  needs. The screen groups blockers apart from suggestions, offers dismissal on
  a suggestion and on nothing else, and, when no guidance model is configured,
  says so in one plain sentence rather than implying a model judged the words.
  """
  use SddOrchestratorWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias SddOrchestrator.Delivery.{Features, GuidedRequirements, Readiness}
  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.SpecificationStore
  alias SddOrchestratorWeb.FeatureReadinessSectionTest.ConfiguredGuidance

  @written %{
    "outcome" => "A person can find a feature by typing part of its title.",
    "users" => "Anyone on the project, owner or participant.",
    "rules" => "An empty search shows every feature.",
    "done" => "Typing three letters of a title finds that feature."
  }

  setup %{conn: conn} do
    context = DeliveryFixtures.delivery_project_fixture()

    {:ok, feature} =
      Features.create(context.project.id, context.owner_actor, %{title: "Search features"})

    %{
      conn: log_in_account(conn, context.account),
      context: context,
      authority: context.workspace,
      project: context.project,
      feature: feature,
      owner: context.owner_actor
    }
  end

  describe "checking readiness with no guidance model configured [AC-03]" do
    test "an empty part is shown as a blocker after one press", ctx do
      write_parts(ctx, Map.delete(@written, "rules"))

      {:ok, view, _html} = live(ctx.conn, feature_path(ctx))

      assert has_element?(view, "[data-readiness-unchecked]")

      html = view |> element("[data-check-readiness]") |> render_click()

      assert html =~ "Blockers"
      assert has_element?(view, "[data-readiness-blocker=\"structural-rules\"]")
      refute has_element?(view, "[data-readiness-blocker=\"structural-outcome\"]")
      refute has_element?(view, "[data-readiness-unchecked]")
    end

    test "the page says no guidance model is configured, and claims nothing else", ctx do
      write_parts(ctx, @written)

      {:ok, view, _html} = live(ctx.conn, feature_path(ctx))

      view |> element("[data-check-readiness]") |> render_click()

      note = view |> element("[data-readiness-guidance=\"not_configured\"]") |> render()

      assert note =~ "No guidance model is configured here."
      assert note =~ "These findings come from the guided parts alone."
      refute note =~ "—"
      assert has_element?(view, "[data-readiness-clear]")
    end
  end

  describe "a configured guidance model [AC-03]" do
    setup do
      previous = Application.get_env(:sdd_orchestrator, :readiness_guidance)
      Application.put_env(:sdd_orchestrator, :readiness_guidance, ConfiguredGuidance)

      on_exit(fn ->
        if previous do
          Application.put_env(:sdd_orchestrator, :readiness_guidance, previous)
        else
          Application.delete_env(:sdd_orchestrator, :readiness_guidance)
        end
      end)

      :ok
    end

    test "its findings are grouped beside the structural ones", ctx do
      write_parts(ctx, Map.delete(@written, "rules"))

      {:ok, view, _html} = live(ctx.conn, feature_path(ctx))

      view |> element("[data-check-readiness]") |> render_click()

      assert has_element?(view, "[data-readiness-blocker=\"structural-rules\"]")
      assert has_element?(view, "[data-readiness-blocker=\"no-error-state\"]")
      assert has_element?(view, "[data-readiness-suggestion=\"tighten-copy\"]")
      refute has_element?(view, "[data-readiness-guidance=\"not_configured\"]")
    end

    test "dismiss is offered on the suggestion and on neither blocker", ctx do
      write_parts(ctx, Map.delete(@written, "rules"))

      {:ok, view, _html} = live(ctx.conn, feature_path(ctx))

      view |> element("[data-check-readiness]") |> render_click()

      assert has_element?(view, "[data-dismiss-suggestion=\"tighten-copy\"]")
      refute has_element?(view, "[data-dismiss-suggestion=\"structural-rules\"]")
      refute has_element?(view, "[data-dismiss-suggestion=\"no-error-state\"]")

      view |> element("[data-dismiss-suggestion=\"tighten-copy\"]") |> render_click()

      refute has_element?(view, "[data-readiness-suggestion=\"tighten-copy\"]")
      assert has_element?(view, "[data-readiness-blocker=\"structural-rules\"]")
      assert has_element?(view, "[data-readiness-blocker=\"no-error-state\"]")

      {:ok, assessment} = Readiness.current(ctx.project.id, ctx.owner, ctx.feature.id)

      assert assessment.dismissed_ids == ["tighten-copy"]
    end
  end

  describe "a feature with no specification of its own [AC-03]" do
    test "the check is refused and the section says why", ctx do
      # The state a feature created before this slice is in, and the state the
      # owner's link control can put any feature back into.
      created = DeliveryFixtures.feature_fixture(ctx.project, ctx.context.account)
      {:ok, unlinked} = Features.unlink_specification(ctx.project.id, ctx.owner, created)

      assert unlinked.specification_id == nil

      {:ok, view, _html} =
        live(ctx.conn, ~p"/projects/#{ctx.project.id}/features/#{unlinked.id}")

      view |> element("[data-check-readiness]") |> render_click()

      assert view |> element("[data-readiness-error]") |> render() =~
               "This feature has no specification to check."

      refute has_element?(view, "[data-readiness-checked]")
    end
  end

  defp feature_path(ctx), do: ~p"/projects/#{ctx.project.id}/features/#{ctx.feature.id}"

  defp write_parts(ctx, parts) do
    {:ok, current} =
      SpecificationStore.get_current(ctx.authority, ctx.project.id, ctx.feature.specification_id)

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
end
