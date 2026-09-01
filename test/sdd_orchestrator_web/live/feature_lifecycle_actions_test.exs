defmodule SddOrchestratorWeb.FeatureLifecycleActionsTest do
  @moduledoc """
  Screen proof for the two lifecycle moves on the feature page (Task 4 of
  specs/41-feature-delivery-from-the-ui, AC-04 and AC-05).

  The board keeps no column control, so this page is the only place a feature
  becomes ready or goes back to draft. Four things have to hold: a blocker-free
  feature moves on one press, a blocker refuses the press and the page names it,
  a save after ready makes the verdict stale and withholds both the ready and
  the start action, and the return to draft works.
  """
  use SddOrchestratorWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias SddOrchestrator.Delivery.{Feature, Features, GuidedRequirements}
  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.Repo
  alias SddOrchestrator.SpecificationStore

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
      authority: context.workspace,
      project: context.project,
      feature: feature,
      owner: context.owner_actor
    }
  end

  describe "making a feature ready [AC-04]" do
    test "one press moves a blocker-free feature to Ready for development", ctx do
      write_parts(ctx, @written)

      {:ok, view, _html} = live(ctx.conn, feature_path(ctx))

      view |> element("[data-check-readiness]") |> render_click()

      assert has_element?(view, "[data-readiness-clear]")
      assert has_element?(view, "[data-make-ready]")

      view |> element("[data-make-ready]") |> render_click()

      assert view |> element("[data-feature-column]") |> render() =~ "Ready for development"
      assert column(ctx) == "ready_for_development"

      # The move is done, so the press that made it is gone and the way back is
      # the action now on offer.
      refute has_element?(view, "[data-make-ready]")
      assert has_element?(view, "[data-back-to-draft]")
      refute has_element?(view, "[data-lifecycle-error]")
    end

    test "a blocker refuses the press, and the page names what blocks it", ctx do
      write_parts(ctx, Map.delete(@written, "rules"))

      {:ok, view, _html} = live(ctx.conn, feature_path(ctx))

      view |> element("[data-check-readiness]") |> render_click()

      refute has_element?(view, "[data-make-ready]")

      # The event a page left open can still send after the verdict moved.
      render_click(view, "make_ready", %{})

      refusal = view |> element("[data-lifecycle-error]") |> render()

      assert refusal =~ "Something still blocks this feature."
      refute refusal =~ "—"

      assert view |> element("[data-readiness-blocker=\"structural-rules\"]") |> render() =~
               "Nothing is written under &quot;Rules that must hold&quot;."

      assert column(ctx) == "draft"
    end
  end

  describe "editing the requirements after the feature is ready [AC-05]" do
    test "the verdict reads as stale, and neither ready nor start is offered", ctx do
      view = made_ready(ctx)

      view
      |> form("#requirements-form", %{
        "requirements" => %{@written | "rules" => "An empty search shows nothing."}
      })
      |> render_submit()

      assert view |> element("[data-readiness-stale]") |> render() =~
               "The requirements changed after this check."

      refute view |> element("[data-readiness-stale]") |> render() =~ "—"

      refute has_element?(view, "[data-make-ready]")
      refute has_element?(view, "[data-start-development]")

      # The column has not moved: a stale verdict withholds the next step, it
      # does not undo the one already taken.
      assert column(ctx) == "ready_for_development"
      assert has_element?(view, "[data-back-to-draft]")
    end

    test "back to draft returns the column, and ready waits for a new check", ctx do
      view = made_ready(ctx)

      view
      |> form("#requirements-form", %{
        "requirements" => %{@written | "rules" => "An empty search shows nothing."}
      })
      |> render_submit()

      view |> element("[data-back-to-draft]") |> render_click()

      assert view |> element("[data-feature-column]") |> render() =~ "Draft"
      assert column(ctx) == "draft"
      refute has_element?(view, "[data-back-to-draft]")

      # Still stale, so the verdict cannot carry the older words into a second
      # promotion until readiness is checked against the new ones.
      assert has_element?(view, "[data-readiness-stale]")
      refute has_element?(view, "[data-make-ready]")

      view |> element("[data-check-readiness]") |> render_click()

      refute has_element?(view, "[data-readiness-stale]")
      assert has_element?(view, "[data-make-ready]")
    end
  end

  describe "returning a ready feature to draft [AC-05]" do
    test "one press puts the feature back in the draft column", ctx do
      view = made_ready(ctx)

      assert column(ctx) == "ready_for_development"

      view |> element("[data-back-to-draft]") |> render_click()

      assert view |> element("[data-feature-column]") |> render() =~ "Draft"
      assert column(ctx) == "draft"
      refute has_element?(view, "[data-back-to-draft]")
      refute has_element?(view, "[data-lifecycle-error]")

      # The verdict is still about these exact words, so the feature can be made
      # ready again without checking anything a second time.
      assert has_element?(view, "[data-make-ready]")
    end
  end

  defp made_ready(ctx) do
    write_parts(ctx, @written)

    {:ok, view, _html} = live(ctx.conn, feature_path(ctx))

    view |> element("[data-check-readiness]") |> render_click()
    view |> element("[data-make-ready]") |> render_click()

    view
  end

  defp column(ctx), do: Repo.get!(Feature, ctx.feature.id).lifecycle_column

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
