defmodule SddOrchestratorWeb.FeatureStartDevelopmentTest do
  @moduledoc """
  Screen proof for starting development from the feature page (Task 8 of
  specs/41-feature-delivery-from-the-ui, AC-07 and AC-08).

  This is the press that commits the project to real, costly work, so these
  tests pin both halves of it: one press creates exactly one run and moves the
  feature, and a press that must not land creates nothing at all.

  The worker here is the test process rather than a Mac. It attaches to the
  same registry the real gateway attaches to, so it can genuinely go away
  between the readout and the press, and it answers the command through the
  exact calls the worker channel makes on its behalf.
  """
  use SddOrchestratorWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias SddOrchestrator.AIRuntimeFixtures

  alias SddOrchestrator.Delivery.{
    AgentRun,
    CommandOutbox,
    DeliveryStore,
    EventIngestion,
    Features,
    RunCommand,
    WorkerAttachment,
    WorkerProtocol
  }

  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.Portability.HostedLocalRepositoryBinding
  alias SddOrchestrator.Repo
  alias SddOrchestratorWeb.WorkerChannel

  setup %{conn: conn} do
    # The stand-in reports every paired worker as attached, which would make the
    # worker precondition impossible to falsify. This proof needs a worker that
    # can actually leave, so it uses the real attachment registry instead.
    previous = Application.get_env(:sdd_orchestrator, :device_worker_stub)
    Application.put_env(:sdd_orchestrator, :device_worker_stub, false)
    on_exit(fn -> Application.put_env(:sdd_orchestrator, :device_worker_stub, previous) end)

    context = DeliveryFixtures.delivery_project_fixture()

    feature =
      DeliveryFixtures.feature_fixture(context.project, context.account,
        title: "Start a run",
        requirements: :filled
      )

    worker = bind_worker(context.project)
    attach_worker(worker)

    %{
      conn: log_in_account(conn, context.account),
      authority: context.workspace,
      project: context.project,
      feature: feature,
      owner: context.owner_actor,
      worker: worker
    }
  end

  describe "the press [AC-07]" do
    test "creates one run, one attempt, one command, and moves the feature", ctx do
      view = made_ready(ctx)

      assert has_element?(view, "[data-start-development]")

      view |> element("[data-start-development]") |> render_click()

      assert [run] = runs(ctx)
      assert run.feature_id == ctx.feature.id
      assert {:ok, attempt} = DeliveryStore.current_attempt(ctx.authority, ctx.project.id, run.id)
      assert attempt.attempt_number == 1
      assert [%RunCommand{operation: "start"}] = CommandOutbox.for_run(run.id)

      assert column(ctx) == "in_development"
      assert view |> element("[data-feature-column]") |> render() =~ "In development"

      # The start flow is over, so nothing on the page offers it again.
      refute has_element?(view, "[data-start-development]")
      refute has_element?(view, "[data-start-error]")
    end
  end

  describe "the run begun [AC-07]" do
    test "the worker's acknowledgement and its first progress reach the open page", ctx do
      view = made_ready(ctx)
      view |> element("[data-start-development]") |> render_click()

      assert [run] = runs(ctx)
      assert {:ok, attempt} = DeliveryStore.current_attempt(ctx.authority, ctx.project.id, run.id)
      assert [command] = CommandOutbox.for_run(run.id)

      # What the worker answers the command with, through the call the channel
      # makes for it.
      assert {:ok, acknowledged} =
               CommandOutbox.acknowledge(command, %{"status" => "accepted", "attempt_number" => 1})

      assert acknowledged.state == "acknowledged"

      worker_reports(ctx, run, attempt, 1, "workspace_ready", "Prepared the workspace")
      worker_reports(ctx, run, attempt, 2, "progress", "Ran the focused implementation checks")

      # Nothing was reloaded: the page was already open when the worker spoke.
      history = view |> element("[data-activity]") |> render()

      assert history =~ "Prepared the workspace"
      assert history =~ "Ran the focused implementation checks"
      refute has_element?(view, "[data-activity-empty]")
    end
  end

  describe "a refused press [AC-08]" do
    test "a worker that left between the readout and the press starts nothing", ctx do
      view = made_ready(ctx)

      assert has_element?(view, "[data-start-precondition=worker][data-precondition-met=true]")
      assert has_element?(view, "[data-start-development]")

      detach_worker(ctx.worker)

      view |> element("[data-start-development]") |> render_click()

      # Nothing exists, and the feature is exactly where it was.
      assert runs(ctx) == []
      assert commands(ctx) == []
      assert column(ctx) == "ready_for_development"

      assert view |> element("[data-start-error]") |> render() =~
               "No worker is connected to this project right now."

      assert has_element?(view, "[data-start-precondition=worker][data-precondition-met=false]")
      refute has_element?(view, "[data-start-development]")
    end

    test "a second press while the run is live is refused, and adds nothing", ctx do
      started = made_ready(ctx)
      stale = open_page(ctx)

      assert has_element?(stale, "[data-start-development]")

      started |> element("[data-start-development]") |> render_click()

      assert [run] = runs(ctx)

      stale |> element("[data-start-development]") |> render_click()

      assert [^run] = runs(ctx)
      assert [_only_command] = commands(ctx)
      assert column(ctx) == "in_development"

      assert stale |> element("[data-start-error]") |> render() =~
               "This feature already has a run going. Nothing new was started."
    end
  end

  defp runs(ctx),
    do: Repo.all(from run in AgentRun, where: run.feature_id == ^ctx.feature.id)

  defp commands(ctx),
    do: Repo.all(from command in RunCommand, where: command.project_id == ^ctx.project.id)

  defp column(ctx) do
    {:ok, feature} = Features.fetch(ctx.project.id, ctx.owner, ctx.feature.id)
    feature.lifecycle_column
  end

  defp feature_path(ctx), do: ~p"/projects/#{ctx.project.id}/features/#{ctx.feature.id}"

  defp open_page(ctx) do
    {:ok, view, _html} = live(ctx.conn, feature_path(ctx))
    view
  end

  # The path a person walks to the button: check the words, make the feature
  # ready, confirm the boundary. Nothing here reaches past the screens.
  defp made_ready(ctx) do
    view = open_page(ctx)

    view |> element("[data-check-readiness]") |> render_click()
    view |> element("[data-make-ready]") |> render_click()
    view |> element("[data-confirm-boundary]") |> render_click()

    view
  end

  # The worker says one thing about the run: it becomes durable history through
  # the ingestion path, and the project's worker traffic is published exactly as
  # the channel publishes it, which is the page's only cue to read again.
  defp worker_reports(ctx, run, attempt, sequence, type, summary) do
    envelope = event(run, attempt, sequence, type, summary)

    assert {:ok, _results} = EventIngestion.ingest(ctx.authority, ctx.project.id, envelope)

    :ok =
      Phoenix.PubSub.broadcast(
        SddOrchestrator.PubSub,
        WorkerChannel.topic(ctx.project.id),
        {:worker_event, envelope}
      )
  end

  defp event(run, attempt, sequence, type, summary) do
    unique = System.unique_integer([:positive])

    %{
      "type" => "event",
      "protocol_version" => WorkerProtocol.version(),
      "event_id" => "evt-#{unique}",
      "run_id" => run.id,
      "command_id" => "cmd-#{unique}",
      "attempt_number" => attempt.attempt_number,
      "fence_token" => attempt.fence_token,
      "sequence" => sequence,
      "event_type" => type,
      "source" => "agent",
      "occurred_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "payload" => %{"summary" => summary}
    }
  end

  # The routing record the connect path writes: which Mac this project's work
  # runs on.
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

    :ok
  end

  defp detach_worker(worker),
    do: Registry.unregister(WorkerAttachment.registry(), worker.device_workspace_id)
end
