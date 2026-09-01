defmodule SddOrchestratorWeb.FeatureStartPreconditionsTest do
  @moduledoc """
  Screen proof for the start readout (Task 6 of
  specs/41-feature-delivery-from-the-ui, AC-06).

  A person who cannot start yet must read why on the page and be given
  somewhere to go, so these tests pin that every unmet item is named with its
  resolving link, that nothing offers a start while one is unmet, that a fully
  met readout says so, and that what the page shows and `Start.available?/3`
  answer are the same thing.

  Two of the five resolving pages are the project owner's own, so they also pin
  that a participant is told who resolves those instead of being handed a link
  that would not open for them.
  """
  use SddOrchestratorWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias SddOrchestrator.AIRuntimeFixtures
  alias SddOrchestrator.Delivery.{Features, GuidedRequirements, Start}
  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.HostedAccess.{SessionCookie, Sessions}
  alias SddOrchestrator.Portability.HostedLocalRepositoryBinding
  alias SddOrchestrator.Repo
  alias SddOrchestrator.RepositoryAssessments.RepositoryExecutionProfile
  alias SddOrchestrator.SpecificationStore

  @written %{
    "outcome" => "A person can start development from the feature page.",
    "users" => "The project owner and the participants invited to it.",
    "rules" => "Nothing starts until every precondition is met.",
    "done" => "The run begins and the feature moves to In development."
  }

  setup %{conn: conn} do
    context = DeliveryFixtures.delivery_project_fixture()

    {:ok, feature} =
      Features.create(context.project.id, context.owner_actor, %{title: "Start a run"})

    %{
      conn: log_in_account(conn, context.account),
      participant_conn:
        log_in_hosted(Phoenix.ConnTest.build_conn(), context.identity.hosted_identity),
      authority: context.workspace,
      project: context.project,
      feature: feature,
      owner: context.owner_actor,
      account: context.account,
      participant_account: context.identity.account
    }
  end

  describe "an unmet precondition [AC-06]" do
    test "each one is named with the link that resolves it, and no start is offered", ctx do
      # A ready feature whose verdict then goes stale, on a project with no
      # approved profile and no worker: four of the five items unmet at once.
      view = made_ready(ctx)
      drop_execution_profile(ctx)

      view
      |> form("#requirements-form", %{
        "requirements" => %{@written | "rules" => "Nothing starts without a check."}
      })
      |> render_submit()

      assert has_element?(view, "[data-start-preconditions]")

      for key <- ~w(ready boundary execution_profile worker) do
        assert has_element?(
                 view,
                 "[data-start-precondition='#{key}'][data-precondition-met=false]"
               )

        assert has_element?(view, "[data-precondition-route='#{key}']")
      end

      assert route(view, "ready") =~ ~s(href="#readiness-heading")
      assert route(view, "boundary") =~ ~s(href="#start-disclosure-heading")
      assert route(view, "execution_profile") =~ ~s(href="/projects/#{ctx.project.id}/profile")
      assert route(view, "worker") =~ ~s(href="/projects/#{ctx.project.id}/overview")

      # Nothing on this page claims a start is possible while an item is unmet.
      refute has_element?(view, "[data-start-development]")
      refute Start.available?(ctx.authority, ctx.owner, subject(ctx))
    end

    test "the sentences say what is true and never claim what cannot be seen", ctx do
      view = made_ready(ctx)

      readout = view |> element("[data-start-preconditions]") |> render()

      assert readout =~ "No worker is connected to this project right now."
      assert readout =~ "Connect this project to a Mac"

      # The control plane cannot see the reader's machine, so the copy never
      # says the app is missing, and it uses no em dash.
      refute readout =~ "not installed"
      refute readout =~ "—"
    end
  end

  describe "every precondition met [AC-06]" do
    test "the readout reads as fully met, and the check agrees", ctx do
      bind_worker(ctx.project)

      view = made_ready(ctx)
      view |> element("[data-confirm-boundary]") |> render_click()

      for key <- ~w(ready boundary execution_profile worker ai_connection) do
        assert has_element?(
                 view,
                 "[data-start-precondition='#{key}'][data-precondition-met=true]"
               )
      end

      refute has_element?(view, "[data-precondition-met=false]")
      refute has_element?(view, "[data-precondition-route]")

      assert Start.available?(ctx.authority, ctx.owner, subject(ctx))
    end

    test "confirming the boundary flips only that item, with nothing else touched", ctx do
      view = made_ready(ctx)

      assert has_element?(view, "[data-start-precondition=boundary][data-precondition-met=false]")

      view |> element("[data-confirm-boundary]") |> render_click()

      assert has_element?(view, "[data-start-precondition=boundary][data-precondition-met=true]")
      assert has_element?(view, "[data-start-precondition=worker][data-precondition-met=false]")
      refute Start.available?(ctx.authority, ctx.owner, subject(ctx))
    end
  end

  describe "a resolving page the acting person cannot open [AC-06]" do
    setup ctx do
      # Bound but not attached, so the worker item is unmet while the AI item
      # still has a worker to look its connections up against.
      previous = Application.get_env(:sdd_orchestrator, :device_worker_stub)
      Application.put_env(:sdd_orchestrator, :device_worker_stub, false)
      on_exit(fn -> Application.put_env(:sdd_orchestrator, :device_worker_stub, previous) end)

      worker = bind_worker(ctx.project)
      drop_execution_profile(ctx)

      %{worker: worker}
    end

    test "a participant reads who resolves it, and is handed no link", ctx do
      two_connections(ctx.participant_account, ctx.worker)

      view = participant_view(ctx)

      for key <- ~w(worker ai_connection) do
        assert has_element?(
                 view,
                 "[data-start-precondition='#{key}'][data-precondition-met=false]"
               )

        refute has_element?(view, "[data-precondition-route='#{key}']")

        assert view |> element("[data-precondition-owner-only='#{key}']") |> render() =~
                 "The project owner resolves this one."
      end

      # The one of the three off-page routes a participant can open keeps its
      # link, so the sentence is about the destination and not about the person.
      assert has_element?(
               view,
               "[data-start-precondition=execution_profile][data-precondition-met=false]"
             )

      assert route(view, "execution_profile") =~ ~s(href="/projects/#{ctx.project.id}/profile")
      refute has_element?(view, "[data-precondition-owner-only=execution_profile]")
    end

    test "the owner is handed the link for those same two items", ctx do
      two_connections(ctx.account, ctx.worker)

      view = made_ready(ctx)

      assert route(view, "worker") =~ ~s(href="/projects/#{ctx.project.id}/overview")
      assert route(view, "ai_connection") =~ ~s(href="/ai-connections")
      refute has_element?(view, "[data-precondition-owner-only]")
    end
  end

  defp subject(ctx), do: %{project: ctx.project, feature: reloaded(ctx)}

  defp reloaded(ctx) do
    {:ok, feature} = Features.fetch(ctx.project.id, ctx.owner, ctx.feature.id)
    feature
  end

  defp route(view, key), do: view |> element("[data-precondition-route='#{key}']") |> render()

  defp made_ready(ctx) do
    write_parts(ctx, @written)

    {:ok, view, _html} = live(ctx.conn, feature_path(ctx))

    view |> element("[data-check-readiness]") |> render_click()
    view |> element("[data-make-ready]") |> render_click()

    view
  end

  defp feature_path(ctx), do: ~p"/projects/#{ctx.project.id}/features/#{ctx.feature.id}"

  defp drop_execution_profile(ctx) do
    Repo.delete_all(
      from profile in RepositoryExecutionProfile, where: profile.project_id == ^ctx.project.id
    )
  end

  # The routing record the connect path writes. The test stand-in reports a
  # paired worker as attached, which is what the browser suite relies on too.
  defp bind_worker(project) do
    worker = AIRuntimeFixtures.personal_ai_worker_fixture()

    %HostedLocalRepositoryBinding{}
    |> HostedLocalRepositoryBinding.changeset(%{
      project_id: project.id,
      worker_id: worker.id,
      last_validated_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()

    worker
  end

  # The owner readies the feature, then the participant opens the page. Both may
  # start, so what is being pinned is the readout the participant reads.
  defp participant_view(ctx) do
    _readied = made_ready(ctx)

    {:ok, view, _html} = live(ctx.participant_conn, feature_path(ctx))

    view
  end

  # Two active connections on the project's worker, which is what leaves the run
  # with a choice nobody has made.
  defp two_connections(account, worker) do
    for label <- ["Personal Codex", "Second Codex"] do
      AIRuntimeFixtures.personal_ai_connection_fixture(%{
        account: account,
        worker: worker,
        label: label
      })
    end
  end

  defp log_in_hosted(conn, hosted_identity) do
    {:ok, _session, cookie} = Sessions.create(hosted_identity, %{})

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(SessionCookie.session_key(), cookie.value)
  end

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
