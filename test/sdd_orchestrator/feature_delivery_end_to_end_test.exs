defmodule SddOrchestrator.FeatureDeliveryEndToEndTest do
  @moduledoc """
  specs/41-feature-delivery-from-the-ui Task 9 proof: the whole loop, walked by
  the two people `specs/07-guided-specification-delivery/` allows, and the log
  review AC-10 asks for written as assertions.

  This file is the slice's closing evidence. Every other task proved one screen
  or one decision. This one walks the path a person actually walks, from an
  empty board to a start command that has left the control plane:

    * create the feature by title on the board,
    * write the four guided requirement parts and save them,
    * check readiness and see nothing blocking,
    * make the feature ready,
    * read every start precondition met,
    * press `Start development`,
    * and watch the command reach the transport.

  Nothing here reaches past a screen while a screen exists. The feature is
  created through the board's own form, every step after it is a press or a
  submit on the feature page, and the identity of the feature comes off the
  board card the person would click. That is the point of the slice: the loop
  was reachable only from tests and the browser-suite seed before it.

  ## Why one walk function

  [AC-10] claims each action succeeds for an invited participant exactly as for
  the owner. Two similar tests would let the two paths drift into asserting
  different things, so both callers run the same `walk_the_path/3` and are held
  to the same assertions at every step. The only difference between them is the
  session the connection carries.

  ## Why the review is a split

  The review AC-10 asks for reads as an inspection: look at what the walk
  logged and find no requirement, no title, no document, and nobody. A person
  doing that proves the one walk they looked at. So it runs here instead, over
  a walk whose every written value carries a mark.

  The capture is split before it is refuted, because two things in it are the
  framework printing a value it was handed rather than this application saying
  anything: Ecto's parameters for a write, and LiveView's parameters for a form
  submission. Both are debug only, and `config/prod.exs` runs the logger at
  `:info`, where neither is emitted. Everything else the walk logged, at every
  level, is refuted against the whole list of marks. Every entry the logger did
  not tag debug is in that half, so the review covers the level a deployment
  actually runs at as well. That LiveView renders a person's typed words at
  debug is reported as a finding rather than worked around.

  ## The worker

  The worker here is the test process rather than a Mac, attached to the same
  registry the real gateway attaches to, exactly as
  `SddOrchestratorWeb.FeatureStartDevelopmentTest` does. The stand-in that
  reports every paired worker as attached is turned off, so the worker
  precondition is answered by a real attachment.

  The last hop, a claimed command handed to a transport, runs on
  `SddOrchestrator.CommandTransportDouble`, the double `specs/33`'s own outbox
  tests use. The command's identity and its durable state change are real; only
  the connected worker is stood in for. `Task 12` installs the real transport
  for development and production; this scenario keeps the double so the round
  trip stays a domain proof that needs no socket. The real hop is what the
  slice's product proof covers.

  `async: false`: the worker stand-in flag, the command transport, and the
  attachment registry are all node-wide.
  """
  use SddOrchestratorWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  alias SddOrchestrator.AIRuntimeFixtures
  alias SddOrchestrator.CommandTransportDouble

  alias SddOrchestrator.Delivery.{
    AgentRun,
    CommandOutbox,
    DeliveryStore,
    Dispatcher,
    Features,
    GuidedRequirements,
    ParticipantGuard,
    RunCommand,
    WorkerAttachment,
    WorkerProtocol
  }

  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.HostedAccess.{SessionCookie, Sessions}
  alias SddOrchestrator.Portability.HostedLocalRepositoryBinding
  alias SddOrchestrator.Repo
  alias SddOrchestrator.SpecificationStore

  # One conspicuous mark inside every value a person writes, so the log review
  # below is looking for something that could only have come from this
  # scenario's own words.
  @mark "sdd41marker"

  @requirements %{
    "outcome" => "A person starts a run without leaving the product. #{@mark}-outcome",
    "users" => "The project owner and the participants invited to it. #{@mark}-users",
    "rules" => "Nothing starts until every precondition is met. #{@mark}-rules",
    "done" => "The run begins and the feature moves on. #{@mark}-done"
  }

  # The placeholder the coding agent owns. It is written into the feature's
  # specification at creation, so the review looks for it too: it is
  # specification content that no diagnostic has any reason to carry.
  @agent_placeholder "The coding agent writes this document."

  @precondition_keys ~w(ready boundary execution_profile worker ai_connection)

  # Where one log entry ends and the next begins: the time the formatter stamps
  # on a message, never on the lines that continue it.
  @entry_start ~r/^\d{2}:\d{2}:\d{2}\.\d{3} /

  setup %{conn: conn} do
    # The stand-in reports every paired worker as attached, which would answer
    # the worker precondition without a worker. This walk uses the real
    # attachment registry instead.
    previous = Application.get_env(:sdd_orchestrator, :device_worker_stub)
    Application.put_env(:sdd_orchestrator, :device_worker_stub, false)
    on_exit(fn -> Application.put_env(:sdd_orchestrator, :device_worker_stub, previous) end)

    on_exit(CommandTransportDouble.install())

    context = DeliveryFixtures.delivery_project_fixture()

    context.project
    |> bind_worker()
    |> attach_worker()

    %{
      conn: log_in_account(conn, context.account),
      participant_conn:
        log_in_hosted(Phoenix.ConnTest.build_conn(), context.identity.hosted_identity),
      context: context,
      authority: context.workspace,
      project: context.project,
      owner: context.owner_actor,
      participant: context.participant_actor
    }
  end

  describe "the round trip [AC-10]" do
    test "the owner walks it, from an empty board to a start command that left", ctx do
      walk_the_path(ctx, ctx.conn, ctx.owner)
    end

    test "the invited participant walks the same one, and every action succeeds", ctx do
      walk_the_path(ctx, ctx.participant_conn, ctx.participant)
    end
  end

  describe "the log review [AC-10]" do
    test "a whole round trip names no requirement, no title, no document, and nobody", ctx do
      markers = leak_markers(ctx)

      {_walked, log} = with_debug_log(fn -> walk_the_path(ctx, ctx.conn, ctx.owner) end)

      entries = entries(log)
      assert_review_covers_the_walk(entries)

      {framework, own} = Enum.split_with(entries, &framework_rendering?/1)

      # The split is proved live before anything is refuted against it. The
      # words are typed into a form and then stored, so the framework's own
      # debug rendering of a submission and of a write does hold them, and a
      # split that had quietly caught everything would make the review below
      # assert nothing.
      assert Enum.any?(framework, &String.contains?(&1, @mark))

      # The half the review runs over is proved to hold this walk's own lines
      # too, at both levels, so the absence found there is an absence and not a
      # capture that never opened.
      assert Enum.any?(own, &String.contains?(&1, "MOUNT SddOrchestratorWeb.FeatureDetailLive"))
      assert Enum.any?(own, &String.contains?(&1, "Sent 200"))

      # Every entry the logger did not tag debug is in this half, so this also
      # settles the claim a deployment lives with: `config/prod.exs` runs the
      # logger at `:info`, where neither framework rendering is emitted at all.
      assert above_debug(entries) != []
      assert above_debug(entries) -- own == []

      refute_leak(join(own), markers, "every line but the framework's own debug rendering")
    end
  end

  # --- the walk -----------------------------------------------------------

  # The path itself, with its assertions inside it. Owner and participant run
  # this same function, so neither can be proved by a weaker check than the
  # other.
  defp walk_the_path(ctx, conn, actor) do
    title = "Deliver a feature #{@mark} #{System.unique_integer([:positive])}"

    feature = create_on_the_board(ctx, conn, actor, title)
    view = write_the_requirements(ctx, conn, feature)

    check_readiness(view)
    make_ready(ctx, view, feature)
    meet_every_precondition(view)

    press_start(ctx, view, feature)
  end

  # [AC-01] The board's own form, and the specification the feature is created
  # with, read back through the store.
  defp create_on_the_board(ctx, conn, actor, title) do
    {:ok, board, _html} = live(conn, ~p"/projects/#{ctx.project.id}/features")

    board |> form("#new-feature-form", feature: %{title: title}) |> render_submit()

    feature_id = created_feature_id!(board, title)

    assert {:ok, feature} = Features.fetch(ctx.project.id, actor, feature_id)
    assert feature.title == title
    assert feature.lifecycle_column == "draft"
    assert feature.specification_id

    assert requirements(ctx, feature) == empty_parts()

    feature
  end

  # [AC-02] The four guided parts, saved from the form and read back out of the
  # feature's own specification.
  defp write_the_requirements(ctx, conn, feature) do
    {:ok, view, _html} =
      live(conn, ~p"/projects/#{ctx.project.id}/features/#{feature.id}")

    assert has_element?(view, "[data-requirements-form]")

    view |> form("#requirements-form", %{"requirements" => @requirements}) |> render_submit()

    refute has_element?(view, "[data-requirements-error]")
    assert requirements(ctx, feature) == @requirements

    view
  end

  # [AC-03] A full document leaves nothing blocking, and the page says so.
  defp check_readiness(view) do
    view |> element("[data-check-readiness]") |> render_click()

    refute has_element?(view, "[data-readiness-error]")
    assert has_element?(view, "[data-readiness-checked]")
    assert has_element?(view, "[data-readiness-clear]")
    refute has_element?(view, "[data-readiness-blockers]")
    refute has_element?(view, "[data-readiness-stale]")
  end

  # [AC-04] The move the board deliberately withholds.
  defp make_ready(ctx, view, feature) do
    view |> element("[data-make-ready]") |> render_click()

    refute has_element?(view, "[data-lifecycle-error]")
    assert column(ctx, feature) == "ready_for_development"
  end

  # [AC-06] The boundary is confirmed by the person doing the starting, and
  # every one of the five items then reads met.
  defp meet_every_precondition(view) do
    view |> element("[data-confirm-boundary]") |> render_click()

    for key <- @precondition_keys do
      assert has_element?(
               view,
               "[data-start-precondition=#{key}][data-precondition-met=true]"
             )
    end

    refute has_element?(view, "[data-precondition-met=false]")
    assert has_element?(view, "[data-start-development]")
  end

  # [AC-07] One press, one run, one attempt, one command, and the command
  # leaves the control plane through the dispatcher that drains the outbox.
  defp press_start(ctx, view, feature) do
    view |> element("[data-start-development]") |> render_click()

    refute has_element?(view, "[data-start-error]")
    refute has_element?(view, "[data-start-development]")

    assert column(ctx, feature) == "in_development"
    assert view |> element("[data-feature-column]") |> render() =~ "In development"

    assert [run] = runs(feature)
    assert run.feature_id == feature.id

    assert {:ok, attempt} = DeliveryStore.current_attempt(ctx.authority, ctx.project.id, run.id)
    assert attempt.attempt_number == 1

    assert [%RunCommand{operation: "start", state: "pending"} = command] =
             CommandOutbox.for_run(run.id)

    assert command.manifest_digest == attempt.manifest_digest

    assert %{delivered: 1} = Dispatcher.dispatch_now(owner: "task-9-#{feature.id}")

    assert Enum.any?(CommandTransportDouble.delivered(), &(&1.id == command.id))
    assert {:ok, delivered} = CommandOutbox.fetch(command.id)
    assert delivered.state == "delivered"

    %{feature: feature, run: run, attempt: attempt, command: delivered}
  end

  # --- the review ---------------------------------------------------------

  # An absence proof is worth only what it looked at, so the capture is proved
  # to hold this walk's own traffic before anything is refuted against it: the
  # handling of every event the slice added, and the writes each one made.
  defp assert_review_covers_the_walk(entries) do
    log = join(entries)

    assert log =~ "QUERY OK"

    for event <- ~w(create_feature save_requirements check_readiness make_ready
                    confirm_boundary start_development) do
      assert log =~ ~s(HANDLE EVENT "#{event}"),
             "the review captured no handling of #{event}"
    end

    for table <- ~w(features specification_revisions readiness_assessments agent_runs
                    run_commands) do
      assert log =~ table, "the review captured no database traffic for #{table}"
    end
  end

  # Everything the walk must never put in a diagnostic: the words a person
  # wrote, the title they chose, the document the coding agent owns, and the
  # two people themselves.
  defp leak_markers(ctx) do
    members = ParticipantGuard.current_members(ctx.project.id, ctx.owner)

    written =
      Enum.map(@requirements, fn {part, body} -> {"the #{part} the person wrote", body} end)

    people =
      Enum.map(members, fn member ->
        {"a member's project display name", member.display_name}
      end)

    emails = [
      {"the owner's email address", ctx.context.owner.external_identity.display_identifier},
      {"the participant's email address",
       ctx.context.identity.external_identity.display_identifier}
    ]

    written ++ people ++ emails ++ [{"the specification's own document", @agent_placeholder}]
  end

  # The two renderings the framework itself writes at debug: the SQL and
  # parameters Ecto logs for a write, and the parameters LiveView logs for a
  # form submission. Both are the framework printing a value it was handed, and
  # both are silent at `:info`. Everything else in the capture is this
  # application's own voice, and the review holds that half to the whole list of
  # marks.
  defp framework_rendering?(entry) do
    debug?(entry) and
      (String.contains?(entry, "QUERY ") or String.contains?(entry, "HANDLE EVENT"))
  end

  defp above_debug(entries), do: Enum.reject(entries, &debug?/1)

  defp debug?(entry), do: String.contains?(entry, "[debug]")

  defp join(entries), do: Enum.join(entries, "\n")

  # One entry per line the formatter stamped with a time, plus every
  # continuation line that followed it.
  defp entries(log) do
    log
    |> String.split("\n")
    |> Enum.reduce([], &collect_entry/2)
    |> Enum.reverse()
  end

  defp collect_entry(line, collected) do
    cond do
      Regex.match?(@entry_start, line) -> [line | collected]
      collected == [] -> [line]
      true -> [hd(collected) <> "\n" <> line | tl(collected)]
    end
  end

  # The failure message names which mark was found, never the value: a review
  # that printed the words to explain itself would be the disclosure.
  defp refute_leak(text, markers, where) do
    for {label, value} <- markers do
      refute String.contains?(text, value), "#{label} appeared in #{where}"
    end
  end

  # `config/test.exs` runs the logger at `:warning`, and the capture handler
  # sits below the primary level filter, so almost everything a healthy walk
  # emits would never reach the capture and the review would assert nothing.
  # The level is lifted for the reviewed walk only.
  defp with_debug_log(fun) do
    previous = Logger.level()
    Logger.configure(level: :debug)

    try do
      with_log(fun)
    after
      Logger.configure(level: previous)
    end
  end

  # --- reading what happened ----------------------------------------------

  # The card the board just rendered, which is what a person would click.
  defp created_feature_id!(board, title) do
    html = render(board)

    assert html =~ title

    ~r/data-feature-id="([^"]+)"/
    |> Regex.scan(html, capture: :all_but_first)
    |> List.flatten()
    |> Enum.find(fn id -> feature_card(html, id) =~ title end)
    |> case do
      nil -> flunk("the board rendered no card for the feature that was just created")
      id -> id
    end
  end

  defp feature_card(html, id) do
    [_before, card] = String.split(html, "data-feature-id=\"#{id}\"", parts: 2)

    card |> String.split("</li>", parts: 2) |> hd()
  end

  defp requirements(ctx, feature) do
    assert {:ok, current} =
             SpecificationStore.get_current(
               ctx.authority,
               ctx.project.id,
               feature.specification_id
             )

    GuidedRequirements.parse(current.revision.requirements_document)
  end

  defp empty_parts,
    do: Map.new(GuidedRequirements.structure(), fn part -> {part.key, ""} end)

  defp column(ctx, feature) do
    assert {:ok, current} = Features.fetch(ctx.project.id, ctx.owner, feature.id)

    current.lifecycle_column
  end

  defp runs(feature),
    do: Repo.all(from run in AgentRun, where: run.feature_id == ^feature.id)

  # --- the two halves -----------------------------------------------------

  defp log_in_hosted(conn, hosted_identity) do
    {:ok, _session, cookie} = Sessions.create(hosted_identity, %{})

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(SessionCookie.session_key(), cookie.value)
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

    worker
  end
end
