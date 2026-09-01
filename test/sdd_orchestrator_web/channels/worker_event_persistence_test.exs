defmodule SddOrchestratorWeb.WorkerEventPersistenceTest do
  @moduledoc """
  Proof that a worker's event survives being announced (Task 11 of
  specs/41-feature-delivery-from-the-ui).

  The channel used to validate an event, broadcast it, and store nothing, so a
  page told to read the run again found nothing new there. These tests pin the
  order that fixes it: the event becomes durable history first, the worker is
  told `accepted` only for one that did, and an event the ingestion path refuses
  is answered with its reason instead of being announced anyway.

  The last test closes the loop a person actually sees. A real worker channel
  speaks, and the page that was already open shows the progress without anyone
  reloading it.
  """
  use SddOrchestratorWeb.ConnCase, async: false

  import Ecto.Query, only: [where: 3]
  # Both test helpers define `assert_reply`, and this file needs the channel's
  # one: what the worker is answered is the whole point.
  import Phoenix.ChannelTest, only: [assert_reply: 3]
  import Phoenix.LiveViewTest, except: [assert_reply: 2, assert_reply: 3]

  alias Phoenix.PubSub
  alias SddOrchestrator.AIRuntimeFixtures
  alias SddOrchestrator.Delivery.ActivityEntry
  alias SddOrchestrator.Delivery.AgentRun
  alias SddOrchestrator.Delivery.DeliveryStore
  alias SddOrchestrator.Delivery.WorkerAttachment
  alias SddOrchestrator.Delivery.WorkerProtocol
  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.Portability.HostedLocalRepositoryBinding
  alias SddOrchestrator.Repo
  alias SddOrchestrator.WorkerDouble
  alias SddOrchestratorWeb.WorkerChannel

  setup %{conn: conn} do
    # The stand-in reports every paired worker as attached, which would hide
    # whether the start precondition is really met. This proof uses the real
    # attachment registry, exactly as the Task 8 screen proof does.
    previous = Application.get_env(:sdd_orchestrator, :device_worker_stub)
    Application.put_env(:sdd_orchestrator, :device_worker_stub, false)
    on_exit(fn -> Application.put_env(:sdd_orchestrator, :device_worker_stub, previous) end)

    context = DeliveryFixtures.delivery_project_fixture()

    feature =
      DeliveryFixtures.feature_fixture(context.project, context.account,
        title: "Persist the run's progress",
        requirements: :filled
      )

    attach_worker(bind_worker(context.project))

    %{
      conn: log_in_account(conn, context.account),
      authority: context.workspace,
      project: context.project,
      feature: feature
    }
  end

  describe "an event this control plane owns" do
    test "becomes activity a reader can find afterwards", ctx do
      %{run: run, attempt: attempt} = dispatched_attempt(ctx)
      channel = joined_worker(ctx)

      ref = report(channel, run, attempt, sequence: 1, summary: "Prepared the workspace")

      assert_reply ref, :ok, %{status: "accepted"}

      assert [entry] = DeliveryStore.list_activity(ctx.authority, ctx.project.id, ctx.feature.id)
      assert entry.actor_kind == "agent"
      assert entry.run_id == run.id
      assert entry.attempt_id == attempt.id
      assert entry.payload["summary"] == "Prepared the workspace"
      assert entry.payload["event_type"] == "progress"
    end

    test "is told accepted only after it was stored", ctx do
      %{run: run, attempt: attempt} = dispatched_attempt(ctx)
      channel = joined_worker(ctx)
      PubSub.subscribe(SddOrchestrator.PubSub, WorkerChannel.topic(ctx.project.id))

      first = report(channel, run, attempt, sequence: 1, summary: "Prepared the workspace")
      assert_reply first, :ok, %{status: "accepted"}
      assert_receive {:worker_event, %{"sequence" => 1}}

      # The same sequence again is the replay the fence and ordering checks
      # exist for. It is refused, so it is never announced, and the history the
      # first one wrote is still the only one there.
      replay = report(channel, run, attempt, sequence: 1, summary: "Prepared the workspace")
      assert_reply replay, :error, %{reason: "duplicate_event"}
      refute_receive {:worker_event, %{"sequence" => 1}}

      assert Repo.aggregate(ActivityEntry, :count) == 1
    end
  end

  describe "an event the ingestion path refuses" do
    test "a superseded attempt's fence is answered with its reason, and stored nowhere", ctx do
      %{run: run, attempt: attempt} = dispatched_attempt(ctx)
      channel = joined_worker(ctx)
      PubSub.subscribe(SddOrchestrator.PubSub, WorkerChannel.topic(ctx.project.id))

      ref =
        report(channel, run, %{attempt | fence_token: attempt.fence_token + 1},
          sequence: 1,
          summary: "Kept working after being replaced"
        )

      assert_reply ref, :error, %{reason: "stale_fence"}
      refute_receive {:worker_event, _envelope}
      assert Repo.aggregate(ActivityEntry, :count) == 0
    end

    test "an unknown run is answered with its reason, and stored nowhere", ctx do
      %{attempt: attempt} = dispatched_attempt(ctx)
      channel = joined_worker(ctx)
      PubSub.subscribe(SddOrchestrator.PubSub, WorkerChannel.topic(ctx.project.id))

      ref =
        report(channel, %{id: Ecto.UUID.generate()}, attempt,
          sequence: 1,
          summary: "Reported on a run this project does not have"
        )

      assert_reply ref, :error, %{reason: "unknown_run"}
      refute_receive {:worker_event, _envelope}
      assert Repo.aggregate(ActivityEntry, :count) == 0
    end
  end

  describe "an event owned outside this control plane's ingestion" do
    test "is published for its own owner exactly as before", ctx do
      %{run: run, attempt: attempt} = dispatched_attempt(ctx)
      channel = joined_worker(ctx)
      PubSub.subscribe(SddOrchestrator.PubSub, WorkerChannel.topic(ctx.project.id))

      ref =
        report(channel, run, attempt,
          sequence: 1,
          summary: "A required check ran",
          event_type: "evidence",
          source: "check"
        )

      assert_reply ref, :ok, %{status: "accepted"}
      assert_receive {:worker_event, %{"event_type" => "evidence"}}

      # Nothing here claims to have stored it. Its own module owns that, and
      # this intake refuses nothing it does not own.
      assert Repo.aggregate(ActivityEntry, :count) == 0
    end
  end

  describe "the page a person left open [AC-07]" do
    test "shows the worker's progress without a reload", ctx do
      view = made_ready(ctx)
      view |> element("[data-start-development]") |> render_click()

      assert [run] = Repo.all(where(AgentRun, [r], r.feature_id == ^ctx.feature.id))

      assert {:ok, attempt} =
               DeliveryStore.current_attempt(ctx.authority, ctx.project.id, run.id)

      channel = joined_worker(ctx)

      ref =
        report(channel, run, attempt,
          sequence: 1,
          summary: "Ran the focused implementation checks"
        )

      assert_reply ref, :ok, %{status: "accepted"}

      history = view |> element("[data-activity]") |> render()

      assert history =~ "Ran the focused implementation checks"
      refute has_element?(view, "[data-activity-empty]")
    end
  end

  # One worker, joined to its own project's topic, speaking the frames the real
  # gateway speaks.
  defp joined_worker(ctx) do
    {:ok, _reply, channel} = WorkerDouble.attach(ctx.project.id)
    channel
  end

  defp report(channel, run, attempt, opts) do
    WorkerDouble.emit_event(channel, %{
      "run_id" => run.id,
      "attempt_number" => attempt.attempt_number,
      "fence_token" => attempt.fence_token,
      "sequence" => Keyword.fetch!(opts, :sequence),
      "event_type" => Keyword.get(opts, :event_type, "progress"),
      "source" => Keyword.get(opts, :source, "agent"),
      "event_id" => "evt-#{System.unique_integer([:positive])}",
      "payload" => %{"summary" => Keyword.fetch!(opts, :summary)}
    })
  end

  # The state a run is in once the dispatcher has handed the attempt to a
  # worker, which is the only state a worker can report from.
  defp dispatched_attempt(ctx) do
    run = DeliveryFixtures.run_fixture(ctx.project, ctx.feature)

    %{run: run, attempt: DeliveryFixtures.attempt_fixture(run)}
  end

  # The path a person walks to the button: check the words, make the feature
  # ready, confirm the boundary.
  defp made_ready(ctx) do
    {:ok, view, _html} =
      live(ctx.conn, ~p"/projects/#{ctx.project.id}/features/#{ctx.feature.id}")

    view |> element("[data-check-readiness]") |> render_click()
    view |> element("[data-make-ready]") |> render_click()
    view |> element("[data-confirm-boundary]") |> render_click()

    view
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
end
