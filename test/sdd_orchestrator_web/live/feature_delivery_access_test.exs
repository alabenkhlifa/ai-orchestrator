defmodule SddOrchestratorWeb.FeatureDeliveryAccessTest do
  @moduledoc """
  specs/41-feature-delivery-from-the-ui Task 9 proof: the second half of
  [AC-10]. A person who is not a member of the project reaches none of what
  this slice added.

  The slice added no route. Everything it built is an event on the feature page
  and the board that already existed, so this file checks both layers.

  ## Nothing opens

  A non-member never gets a socket for either screen, which is what puts every
  event out of reach. That is asserted for an account holder who belongs to
  another project, for a hosted identity who belongs to another project, and
  for a visitor with no session at all.

  ## Every event refuses on its own

  A page that cannot be opened is only half the answer: the handlers must
  refuse for themselves, or a page left open would keep working after its
  person stopped being allowed to use it. So each of the seven events this
  slice added is sent to a page that was opened while the person was still a
  participant, after their participation was removed:

    * `validate_requirements` and `save_requirements` (Task 2),
    * `check_readiness` and `dismiss_suggestion` (Task 3),
    * `make_ready` and `back_to_draft` (Task 4),
    * `start_development` (Task 8).

  `create_feature` on the board is checked too. The event predates the slice,
  but Task 1 changed what it does, and it is the first step of the round trip.

  Each event gets its own page, because a refused one navigates away and a dead
  view cannot answer the next press. Every check asserts the durable state as
  well as the answer: a refusal that still wrote something would not be a
  refusal.

  `async: false`: the worker stand-in flag and the attachment registry are
  node-wide.
  """
  use SddOrchestratorWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias SddOrchestrator.AIRuntimeFixtures
  alias SddOrchestrator.Delivery.{AgentRun, Features, Readiness, RunCommand, WorkerAttachment}
  alias SddOrchestrator.Delivery.WorkerProtocol
  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.HostedAccess.{SessionCookie, Sessions}
  alias SddOrchestrator.Participation.Revocations
  alias SddOrchestrator.Portability.HostedLocalRepositoryBinding
  alias SddOrchestrator.Repo
  alias SddOrchestrator.Specifications.SpecificationRevision

  @written %{
    "outcome" => "Somebody who is not on this project should never store this.",
    "users" => "Nobody, because this save must be refused.",
    "rules" => "A removed member writes nothing.",
    "done" => "The stored revisions are exactly what they were."
  }

  setup %{conn: conn} do
    # The stand-in answers the worker precondition without a worker, which would
    # let the start check pass for a reason this file is not testing.
    previous = Application.get_env(:sdd_orchestrator, :device_worker_stub)
    Application.put_env(:sdd_orchestrator, :device_worker_stub, false)
    on_exit(fn -> Application.put_env(:sdd_orchestrator, :device_worker_stub, previous) end)

    context = DeliveryFixtures.delivery_project_fixture()

    feature =
      DeliveryFixtures.feature_fixture(context.project, context.account,
        title: "Reachable only by members",
        requirements: :filled
      )

    attach_worker(bind_worker(context.project))

    %{
      conn: conn,
      context: context,
      project: context.project,
      feature: feature,
      owner: context.owner_actor,
      account: context.account,
      participant: context.identity.hosted_identity
    }
  end

  describe "the screens a non-member asks for [AC-10]" do
    test "an account holder from another project opens neither the board nor the feature", ctx do
      %{account: outsider} = DeliveryFixtures.delivery_project_fixture()

      assert {:error, {:live_redirect, %{to: "/projects"}}} =
               ctx.conn |> log_in_account(outsider) |> live(board_path(ctx))

      assert {:error, {:live_redirect, %{to: "/projects"}}} =
               build_conn() |> log_in_account(outsider) |> live(feature_path(ctx))
    end

    test "a hosted identity from another project opens neither one", ctx do
      other = DeliveryFixtures.delivery_project_fixture()

      assert {:error, {:live_redirect, %{to: "/projects"}}} =
               ctx.conn
               |> log_in_hosted(other.identity.hosted_identity)
               |> live(board_path(ctx))

      assert {:error, {:live_redirect, %{to: "/projects"}}} =
               build_conn()
               |> log_in_hosted(other.identity.hosted_identity)
               |> live(feature_path(ctx))
    end

    test "a visitor with no session opens neither one", ctx do
      assert {:error, {:live_redirect, %{to: "/projects"}}} = live(ctx.conn, board_path(ctx))

      assert {:error, {:live_redirect, %{to: "/projects"}}} =
               live(build_conn(), feature_path(ctx))
    end

    test "a removed participant cannot open the feature page again", ctx do
      revoke(ctx)

      assert {:error, {:live_redirect, %{to: "/projects"}}} =
               ctx.conn |> log_in_hosted(ctx.participant) |> live(feature_path(ctx))
    end
  end

  describe "the events, on a page that outlived the membership [AC-10]" do
    test "create_feature adds nothing to the board", ctx do
      before = feature_count(ctx)

      {:ok, board, _html} = live(participant_conn(ctx), board_path(ctx))

      revoke(ctx)

      render_submit(board, "create_feature", %{"feature" => %{"title" => "Not mine to add"}})

      assert_redirect(board, ~p"/projects")
      assert feature_count(ctx) == before
    end

    test "validate_requirements writes nothing, because it stores nothing", ctx do
      before = revisions(ctx)
      view = open_page(ctx)

      revoke(ctx)

      render_change(view, "validate_requirements", %{"requirements" => @written})

      # This one holds no guard, because it holds no write: the typed words stay
      # in the socket and never reach the store. What must stay true is that the
      # stored document is untouched, which is asserted rather than assumed.
      assert revisions(ctx) == before
      assert render(view) =~ "data-requirements-form"
    end

    test "save_requirements stores no revision", ctx do
      before = revisions(ctx)
      view = open_page(ctx)

      revoke(ctx)

      render_submit(view, "save_requirements", %{"requirements" => @written})

      assert_redirect(view, ~p"/projects")
      assert revisions(ctx) == before
    end

    test "check_readiness records no verdict", ctx do
      view = open_page(ctx)

      revoke(ctx)

      render_click(view, "check_readiness")

      assert_redirect(view, ~p"/projects")
      assert Readiness.current(ctx.project.id, ctx.owner, ctx.feature.id) == {:error, :not_found}
    end

    test "dismiss_suggestion is refused before the finding is even looked up", ctx do
      view = open_page(ctx)

      # A verdict has to be on the page for the event to reach the domain at
      # all, so the person checks readiness while they are still a participant.
      render_click(view, "check_readiness")
      assert {:ok, checked} = Readiness.current(ctx.project.id, ctx.owner, ctx.feature.id)

      revoke(ctx)

      render_click(view, "dismiss_suggestion", %{"id" => "structural-outcome"})

      assert_redirect(view, ~p"/projects")
      assert {:ok, unchanged} = Readiness.current(ctx.project.id, ctx.owner, ctx.feature.id)
      assert unchanged.version == checked.version
      assert unchanged.dismissed_ids == checked.dismissed_ids
    end

    test "make_ready leaves the feature in draft", ctx do
      view = open_page(ctx)

      render_click(view, "check_readiness")

      revoke(ctx)

      render_click(view, "make_ready")

      assert_redirect(view, ~p"/projects")
      assert column(ctx) == "draft"
    end

    test "back_to_draft leaves the feature where the member left it", ctx do
      view = open_page(ctx)

      render_click(view, "check_readiness")
      render_click(view, "make_ready")
      assert column(ctx) == "ready_for_development"

      revoke(ctx)

      render_click(view, "back_to_draft")

      assert_redirect(view, ~p"/projects")
      assert column(ctx) == "ready_for_development"
    end

    test "start_development starts nothing, and the action goes with the membership", ctx do
      view = open_page(ctx)

      render_click(view, "check_readiness")
      render_click(view, "make_ready")
      view |> element("[data-confirm-boundary]") |> render_click()

      # The press was genuinely available a moment before, so the refusal below
      # is the removal doing the work and not a precondition that was never met.
      assert has_element?(view, "[data-start-development]")

      revoke(ctx)

      render_click(view, "start_development")

      # Nothing was created, nothing moved, and the page no longer offers it.
      assert runs(ctx) == []
      assert commands(ctx) == []
      assert column(ctx) == "ready_for_development"
      assert has_element?(view, "[data-start-error]")
      refute has_element?(view, "[data-start-development]")
      refute has_element?(view, "[data-precondition-met=true]")
    end
  end

  # --- the two halves -----------------------------------------------------

  defp open_page(ctx) do
    {:ok, view, _html} = live(participant_conn(ctx), feature_path(ctx))

    view
  end

  defp participant_conn(ctx), do: log_in_hosted(build_conn(), ctx.participant)

  defp revoke(ctx) do
    assert {:ok, _removed} = Revocations.remove(ctx.project, ctx.account.id, ctx.participant.id)

    :ok
  end

  defp board_path(ctx), do: ~p"/projects/#{ctx.project.id}/features"

  defp feature_path(ctx), do: ~p"/projects/#{ctx.project.id}/features/#{ctx.feature.id}"

  # --- reading what did not happen ----------------------------------------

  defp column(ctx) do
    assert {:ok, feature} = Features.fetch(ctx.project.id, ctx.owner, ctx.feature.id)

    feature.lifecycle_column
  end

  defp revisions(ctx) do
    Repo.all(
      from revision in SpecificationRevision,
        where: revision.specification_id == ^ctx.feature.specification_id,
        order_by: revision.inserted_at,
        select: revision.id
    )
  end

  defp feature_count(ctx) do
    Repo.aggregate(
      from(feature in SddOrchestrator.Delivery.Feature,
        where: feature.project_id == ^ctx.project.id
      ),
      :count
    )
  end

  defp runs(ctx),
    do: Repo.all(from run in AgentRun, where: run.feature_id == ^ctx.feature.id)

  defp commands(ctx),
    do: Repo.all(from command in RunCommand, where: command.project_id == ^ctx.project.id)

  defp log_in_hosted(conn, hosted_identity) do
    {:ok, _session, cookie} = Sessions.create(hosted_identity, %{})

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(SessionCookie.session_key(), cookie.value)
  end

  # The routing record the connect path writes: which Mac this project's work
  # runs on. Without it the start action would be unavailable for a reason that
  # has nothing to do with membership.
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

  defp attach_worker(worker) do
    {:ok, _attached} =
      WorkerAttachment.attach(worker.device_workspace_id, %{
        worker_id: worker.id,
        protocol_version: WorkerProtocol.version(),
        capabilities: []
      })

    worker
  end
end
