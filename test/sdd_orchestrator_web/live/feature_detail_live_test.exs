defmodule SddOrchestratorWeb.FeatureDetailLiveTest do
  @moduledoc """
  Screen proof for the feature detail assignment controls (Task 9).

  The screen has to make three things true at once: any current participant can
  change who is working on a feature, the selector only ever offers people who
  are authorized right now, and nobody's email address appears anywhere on the
  way through.
  """
  use SddOrchestratorWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias SddOrchestrator.Delivery.{Assignment, BlockingQuestion, Feature}
  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.HostedAccess.{SessionCookie, Sessions}
  alias SddOrchestrator.Participation
  alias SddOrchestrator.Participation.Revocations
  alias SddOrchestrator.ParticipationDeliveryDouble
  alias SddOrchestrator.Repo

  setup do
    previous = Application.get_env(:sdd_orchestrator, :participation_email_delivery)

    Application.put_env(
      :sdd_orchestrator,
      :participation_email_delivery,
      ParticipationDeliveryDouble
    )

    ParticipationDeliveryDouble.succeed()

    on_exit(fn ->
      if previous do
        Application.put_env(:sdd_orchestrator, :participation_email_delivery, previous)
      else
        Application.delete_env(:sdd_orchestrator, :participation_email_delivery)
      end
    end)

    context = DeliveryFixtures.delivery_project_fixture()
    feature = DeliveryFixtures.feature_fixture(context.project, context.account)

    %{context: context, project: context.project, feature: feature, account: context.account}
  end

  describe "presentation" do
    test "shows the creator, the assignee, and who answers questions", %{
      conn: conn,
      context: context,
      project: project,
      feature: feature,
      account: account
    } do
      owner_label = Participation.owner_profile(project.id).display_name

      {:ok, view, html} =
        conn |> log_in_account(account) |> live(feature_path(project, feature))

      assert html =~ "data-screen=\"feature-detail\""
      assert view |> element("[data-feature-creator]") |> render() =~ owner_label
      assert view |> element("[data-feature-assignee]") |> render() =~ "Nobody yet"

      # Responsibility is derived: unassigned means the creator answers.
      assert view |> element("[data-feature-responsible]") |> render() =~ owner_label

      refute html =~ context.identity.hosted_identity.id
      refute html =~ "@example.com"
    end

    test "offers exactly the current members in the selector", %{
      conn: conn,
      context: context,
      project: project,
      feature: feature,
      account: account
    } do
      member_label = Participation.member_profile(project.id, context.identity.account.id)

      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(feature_path(project, feature))

      select = view |> element("[data-assignment-select]") |> render()

      assert select =~ "Nobody yet"
      assert select =~ member_label.display_name
      assert select =~ Participation.owner_profile(project.id).display_name
      refute select =~ "@example.com"
    end
  end

  describe "assigning" do
    test "an owner assigns another current participant [AC-07]", %{
      conn: conn,
      context: context,
      project: project,
      feature: feature,
      account: account
    } do
      target = context.identity.account

      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(feature_path(project, feature))

      view
      |> form("#assignment-form", %{"assignment" => %{"account_id" => target.id}})
      |> render_change()

      assert Repo.get!(Feature, feature.id).assigned_account_id == target.id

      label = Participation.member_profile(project.id, target.id).display_name
      assert view |> element("[data-feature-assignee]") |> render() =~ label
      assert view |> element("[data-feature-responsible]") |> render() =~ label
    end

    test "a participant assigns through their hosted session", %{
      conn: conn,
      context: context,
      project: project,
      feature: feature
    } do
      {:ok, view, _html} =
        conn
        |> log_in_hosted(context.identity.hosted_identity)
        |> live(feature_path(project, feature))

      view
      |> form("#assignment-form", %{
        "assignment" => %{"account_id" => context.identity.account.id}
      })
      |> render_change()

      assert Repo.get!(Feature, feature.id).assigned_account_id == context.identity.account.id
    end

    test "`Assign to me` takes the feature for the acting participant [AC-08]", %{
      conn: conn,
      context: context,
      project: project,
      feature: feature
    } do
      {:ok, view, _html} =
        conn
        |> log_in_hosted(context.identity.hosted_identity)
        |> live(feature_path(project, feature))

      view |> element("[data-assign-to-me]") |> render_click()

      assert Repo.get!(Feature, feature.id).assigned_account_id == context.identity.account.id
    end

    test "clearing the assignment returns the question to the creator", %{
      conn: conn,
      context: context,
      project: project,
      feature: feature,
      account: account
    } do
      {:ok, assigned} =
        Assignment.assign(project.id, context.owner_actor, feature, context.identity.account.id)

      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(feature_path(project, assigned))

      view
      |> form("#assignment-form", %{"assignment" => %{"account_id" => ""}})
      |> render_change()

      refute Repo.get!(Feature, feature.id).assigned_account_id

      owner_label = Participation.owner_profile(project.id).display_name
      assert view |> element("[data-feature-responsible]") |> render() =~ owner_label
    end

    test "a target who left is rejected inline without changing the feature", %{
      conn: conn,
      context: context,
      project: project,
      feature: feature,
      account: account
    } do
      stale_target = context.identity.account.id

      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(feature_path(project, feature))

      {:ok, _removed} =
        Revocations.remove(project, account.id, context.identity.hosted_identity.id)

      view
      |> form("#assignment-form", %{"assignment" => %{"account_id" => stale_target}})
      |> render_change()

      assert view |> element("[data-assignment-error]") |> render() =~ "not on this project"
      refute Repo.get!(Feature, feature.id).assigned_account_id
    end
  end

  describe "authorization" do
    test "an outsider never reaches the screen", %{conn: conn, project: project, feature: feature} do
      outsider = SddOrchestrator.AccountsFixtures.account_fixture()

      assert {:error, {:live_redirect, %{to: "/projects"}}} =
               conn |> log_in_account(outsider) |> live(feature_path(project, feature))
    end

    test "an unauthenticated visitor never reaches the screen", %{
      conn: conn,
      project: project,
      feature: feature
    } do
      assert {:error, {:live_redirect, %{to: "/projects"}}} =
               live(conn, feature_path(project, feature))
    end

    test "a departed participant loses the screen immediately", %{
      conn: conn,
      context: context,
      project: project,
      feature: feature,
      account: account
    } do
      {:ok, _removed} =
        Revocations.remove(project, account.id, context.identity.hosted_identity.id)

      assert {:error, {:live_redirect, %{to: "/projects"}}} =
               conn
               |> log_in_hosted(context.identity.hosted_identity)
               |> live(feature_path(project, feature))
    end

    test "a feature from another project is not reachable here", %{
      conn: conn,
      project: project,
      account: account
    } do
      other = DeliveryFixtures.delivery_project_fixture()
      other_feature = DeliveryFixtures.feature_fixture(other.project, other.account)

      assert {:error, {:live_redirect, %{to: path}}} =
               conn |> log_in_account(account) |> live(feature_path(project, other_feature))

      assert path == "/projects/#{project.id}/features"
    end
  end

  describe "comments" do
    test "a participant posts a comment that appears under their project name", %{
      conn: conn,
      context: context,
      project: project,
      feature: feature
    } do
      label = Participation.member_profile(project.id, context.identity.account.id).display_name

      {:ok, view, _html} =
        conn
        |> log_in_hosted(context.identity.hosted_identity)
        |> live(feature_path(project, feature))

      assert has_element?(view, "[data-comments-empty]")

      view
      |> form("#comment-form", %{"comment" => %{"body" => "The empty state needs work."}})
      |> render_submit()

      assert view |> element("[data-comment-body]") |> render() =~ "The empty state needs work."
      assert view |> element("[data-comment-author]") |> render() =~ label
      refute has_element?(view, "[data-comments-empty]")
    end

    test "a pasted address is rejected inline and never posted", %{
      conn: conn,
      project: project,
      feature: feature,
      account: account
    } do
      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(feature_path(project, feature))

      view
      |> form("#comment-form", %{"comment" => %{"body" => "ask alex@example.com"}})
      |> render_submit()

      assert view |> element("#comment-body-error") |> render() =~ "Remove the address"
      assert has_element?(view, "[data-comments-empty]")
    end

    test "an empty comment is rejected inline", %{
      conn: conn,
      project: project,
      feature: feature,
      account: account
    } do
      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(feature_path(project, feature))

      view |> form("#comment-form", %{"comment" => %{"body" => "   "}}) |> render_submit()

      assert view |> element("#comment-body-error") |> render() =~ "Write something"
    end

    test "a resubmitted comment is reported rather than posted twice", %{
      conn: conn,
      project: project,
      feature: feature,
      account: account
    } do
      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(feature_path(project, feature))

      for _submit <- 1..2 do
        view
        |> form("#comment-form", %{"comment" => %{"body" => "Double clicked."}})
        |> render_submit()
      end

      assert view |> element("#comment-body-error") |> render() =~ "already posted"
      assert view |> render() |> then(&Regex.scan(~r/data-comment-body/, &1)) |> length() == 1
    end
  end

  describe "the start disclosure [AC-36]" do
    setup %{project: project, account: account} do
      previous = Application.get_env(:sdd_orchestrator, :processing_boundary)

      Application.put_env(:sdd_orchestrator, :processing_boundary,
        execution_location: "this computer",
        agent_provider: "configured-agent",
        model_provider: "configured-model",
        transfers: []
      )

      on_exit(fn ->
        if previous do
          Application.put_env(:sdd_orchestrator, :processing_boundary, previous)
        else
          Application.delete_env(:sdd_orchestrator, :processing_boundary)
        end
      end)

      ready = DeliveryFixtures.feature_fixture(project, account)

      {:ok, ready} =
        ready
        |> Feature.transition_changeset("ready_for_development", ready.state_version)
        |> Repo.update()

      %{ready: ready}
    end

    test "is absent until the feature is ready for development", %{
      conn: conn,
      project: project,
      feature: feature,
      account: account
    } do
      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(feature_path(project, feature))

      refute has_element?(view, "[data-start-disclosure]")
    end

    test "shows where the work runs and whether content leaves its store", %{
      conn: conn,
      project: project,
      ready: ready,
      account: account
    } do
      {:ok, view, _html} = conn |> log_in_account(account) |> live(feature_path(project, ready))

      assert view |> element("[data-disclosure-location]") |> render() =~ "this computer"
      assert view |> element("[data-disclosure-agent]") |> render() =~ "configured-agent"
      assert view |> element("[data-disclosure-model]") |> render() =~ "configured-model"

      assert view |> element("[data-disclosure-preview]") |> render() =~
               "No preview is configured"

      assert view |> element("[data-disclosure-transfer]") |> render() =~ "Stays in this project"
    end

    test "a participant confirms once and is not asked again", %{
      conn: conn,
      project: project,
      ready: ready,
      account: account
    } do
      {:ok, view, _html} = conn |> log_in_account(account) |> live(feature_path(project, ready))

      assert has_element?(view, "[data-confirm-boundary]")
      refute has_element?(view, "[data-disclosure-acknowledged]")

      view |> element("[data-confirm-boundary]") |> render_click()

      assert has_element?(view, "[data-disclosure-acknowledged]")
      refute has_element?(view, "[data-confirm-boundary]")

      {:ok, revisited, _html} =
        conn |> log_in_account(account) |> live(feature_path(project, ready))

      assert has_element?(revisited, "[data-disclosure-acknowledged]")
    end

    test "a boundary that changed while the dialog was open is re-shown", %{
      conn: conn,
      project: project,
      ready: ready,
      account: account
    } do
      {:ok, view, _html} = conn |> log_in_account(account) |> live(feature_path(project, ready))

      Application.put_env(:sdd_orchestrator, :processing_boundary,
        execution_location: "remote worker",
        agent_provider: "configured-agent",
        model_provider: "configured-model",
        transfers: ["specifications"]
      )

      view |> element("[data-confirm-boundary]") |> render_click()

      assert has_element?(view, "[data-disclosure-changed]")
      refute has_element?(view, "[data-disclosure-acknowledged]")
      assert view |> element("[data-disclosure-location]") |> render() =~ "remote worker"
      assert view |> element("[data-disclosure-transfer]") |> render() =~ "Leaves this project"
    end
  end

  describe "the blocking question [AC-02] [AC-17]" do
    setup %{project: project, account: account} do
      blocked = project |> DeliveryFixtures.feature_fixture(account) |> in_development()
      run = DeliveryFixtures.run_fixture(project, blocked)

      %{blocked: blocked, run: run}
    end

    test "is absent while nothing is waiting on a decision", %{
      conn: conn,
      project: project,
      blocked: blocked,
      account: account
    } do
      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(feature_path(project, blocked))

      refute has_element?(view, "[data-blocking-question]")
      refute has_element?(view, "[data-feature-status]")
    end

    test "shows the question and its context without moving the feature", %{
      conn: conn,
      project: project,
      blocked: blocked,
      run: run,
      account: account
    } do
      ask(project, blocked, run, %{
        question: "Should a departed member's comments stay visible?",
        context: "The retention rule says active project lifetime."
      })

      {:ok, updated} =
        blocked |> Feature.status_changeset("blocked", blocked.state_version) |> Repo.update()

      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(feature_path(project, updated))

      assert view |> element("[data-feature-status]") |> render() =~ "Blocked"
      assert view |> element("[data-feature-column]") |> render() =~ "In development"

      assert view |> element("[data-question-text]") |> render() =~
               "Should a departed member&#39;s comments stay visible?"

      assert view |> element("[data-question-context]") |> render() =~ "active project lifetime"
      assert view |> element("[data-question-branch]") |> render() =~ run.branch
    end

    test "an answered question stops waiting on the screen", %{
      conn: conn,
      project: project,
      blocked: blocked,
      run: run,
      account: account
    } do
      question = ask(project, blocked, run, %{question: "Which retention window applies?"})

      {:ok, _answered} =
        question
        |> BlockingQuestion.resolve_changeset(
          "answered",
          question.state_version,
          Ecto.UUID.generate()
        )
        |> Repo.update()

      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(feature_path(project, blocked))

      refute has_element?(view, "[data-blocking-question]")
    end
  end

  describe "who the blocking question is waiting on [AC-05] [AC-06]" do
    setup %{project: project, account: account} do
      blocked = project |> DeliveryFixtures.feature_fixture(account) |> in_development()
      run = DeliveryFixtures.run_fixture(project, blocked)
      ask(project, blocked, run, %{question: "Which retention window applies?"})

      %{blocked: blocked, run: run}
    end

    test "names the assigned participant even though the creator is someone else [AC-05]", %{
      conn: conn,
      context: context,
      project: project,
      blocked: blocked,
      account: account
    } do
      member_label = Participation.member_profile(project.id, context.identity.account.id)

      {:ok, assigned} =
        Assignment.assign(project.id, context.owner_actor, blocked, context.identity.account.id)

      {:ok, view, html} =
        conn |> log_in_account(account) |> live(feature_path(project, assigned))

      assert view |> element("[data-question-responder]") |> render() =~
               member_label.display_name

      # The creator is reading it, so the screen does not claim the decision is
      # theirs.
      assert view |> element("[data-blocking-question]") |> render() =~ "Waiting on a decision"
      refute html =~ "@example.com"
    end

    test "names the creator when nobody is assigned [AC-06]", %{
      conn: conn,
      project: project,
      blocked: blocked,
      account: account
    } do
      owner_label = Participation.owner_profile(project.id).display_name

      {:ok, view, html} =
        conn |> log_in_account(account) |> live(feature_path(project, blocked))

      assert view |> element("[data-question-responder]") |> render() =~ owner_label

      assert view |> element("[data-blocking-question]") |> render() =~
               "Waiting on your decision"

      refute html =~ "@example.com"
    end

    test "tells the assigned responder the decision is theirs [AC-05]", %{
      conn: conn,
      context: context,
      project: project,
      blocked: blocked
    } do
      {:ok, assigned} =
        Assignment.assign(project.id, context.owner_actor, blocked, context.identity.account.id)

      {:ok, view, html} =
        conn
        |> log_in_hosted(context.identity.hosted_identity)
        |> live(feature_path(project, assigned))

      assert view |> element("[data-blocking-question]") |> render() =~
               "Waiting on your decision"

      refute html =~ "@example.com"
    end

    test "names the owner once the assignee has left", %{
      conn: conn,
      context: context,
      project: project,
      blocked: blocked,
      account: account
    } do
      member_label = Participation.member_profile(project.id, context.identity.account.id)

      {:ok, assigned} =
        Assignment.assign(project.id, context.owner_actor, blocked, context.identity.account.id)

      {:ok, _removed} =
        Revocations.remove(project, account.id, context.identity.hosted_identity.id)

      owner_label = Participation.owner_profile(project.id).display_name

      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(feature_path(project, assigned))

      responder = view |> element("[data-question-responder]") |> render()

      assert responder =~ owner_label
      refute responder =~ member_label.display_name
    end
  end

  defp in_development(feature) do
    {:ok, ready} =
      feature
      |> Feature.transition_changeset("ready_for_development", feature.state_version)
      |> Repo.update()

    {:ok, developing} =
      ready
      |> Feature.transition_changeset("in_development", ready.state_version)
      |> Repo.update()

    developing
  end

  describe "answering the blocking question [AC-18]" do
    setup %{project: project, context: context, account: account} do
      {:ok, _current} =
        SddOrchestrator.SpecificationStore.create(
          context.workspace,
          project.id,
          SddOrchestrator.SpecificationFixtures.specification_attrs(),
          actor_ref: "owner"
        )

      previous = Application.get_env(:sdd_orchestrator, :delivery_execution)

      Application.put_env(:sdd_orchestrator, :delivery_execution,
        approved_slice: "slice-07",
        repository_base_revision: "a1b2c3d4e5f6a7b8",
        required_checks: [],
        agent_ref: %{"provider" => "configured-agent"},
        worker_ref: %{"target" => "configured-worker"}
      )

      on_exit(fn ->
        if previous do
          Application.put_env(:sdd_orchestrator, :delivery_execution, previous)
        else
          Application.delete_env(:sdd_orchestrator, :delivery_execution)
        end
      end)

      feature = project |> DeliveryFixtures.feature_fixture(account) |> in_development()
      run = DeliveryFixtures.run_fixture(project, feature)
      attempt = DeliveryFixtures.attempt_fixture(run, %{fence_token: 1})

      {:ok, running} =
        run
        |> SddOrchestrator.Delivery.AgentRun.transition_changeset("running", run.state_version)
        |> Repo.update()

      question =
        ask(project, feature, running, %{
          question: "Should archived items appear?",
          context: "Unclear."
        })

      {:ok, blocked_run} =
        running
        |> SddOrchestrator.Delivery.AgentRun.transition_changeset(
          "blocked",
          running.state_version
        )
        |> Repo.update()

      {:ok, blocked_feature} =
        feature |> Feature.status_changeset("blocked", feature.state_version) |> Repo.update()

      %{feature: blocked_feature, run: blocked_run, attempt: attempt, question: question}
    end

    test "the responder answers and the run continues", %{
      conn: conn,
      project: project,
      feature: feature,
      account: account
    } do
      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(feature_path(project, feature))

      assert has_element?(view, "[data-answer-form]")

      view
      |> form("#answer-form", %{"answer" => %{"body" => "Yes, include archived items."}})
      |> render_submit()

      # The status clears and the feature keeps its place in development.
      refute has_element?(view, "[data-blocking-question]")
      assert view |> element("[data-feature-column]") |> render() =~ "In development"
      assert Repo.get!(Feature, feature.id).status == "none"
    end

    test "an empty answer is refused inline and nothing resumes", %{
      conn: conn,
      project: project,
      feature: feature,
      run: run,
      account: account
    } do
      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(feature_path(project, feature))

      view |> form("#answer-form", %{"answer" => %{"body" => "   "}}) |> render_submit()

      assert view |> element("#answer-body-error") |> render() =~ "Write your decision"
      assert Repo.get!(SddOrchestrator.Delivery.AgentRun, run.id).state == "blocked"
    end

    test "someone who is not the responder is not offered the form", %{
      conn: conn,
      context: context,
      project: project,
      feature: feature
    } do
      {:ok, view, _html} =
        conn
        |> log_in_hosted(context.identity.hosted_identity)
        |> live(feature_path(project, feature))

      assert has_element?(view, "[data-blocking-question]")
      refute has_element?(view, "[data-answer-form]")
    end
  end

  describe "the failed run [AC-34]" do
    setup %{project: project, account: account} do
      previous = Application.get_env(:sdd_orchestrator, :delivery_execution)

      Application.put_env(:sdd_orchestrator, :delivery_execution,
        approved_slice: "slice-07",
        repository_base_revision: "a1b2c3d4e5f6a7b8",
        required_checks: [],
        agent_ref: %{"provider" => "configured-agent"},
        worker_ref: %{"target" => "configured-worker"}
      )

      on_exit(fn ->
        if previous do
          Application.put_env(:sdd_orchestrator, :delivery_execution, previous)
        else
          Application.delete_env(:sdd_orchestrator, :delivery_execution)
        end
      end)

      feature = project |> DeliveryFixtures.feature_fixture(account) |> in_development()
      run = DeliveryFixtures.run_fixture(project, feature, %{initiator_account_id: account.id})
      attempt = DeliveryFixtures.attempt_fixture(run, %{fence_token: 1})

      {:ok, running} =
        run
        |> SddOrchestrator.Delivery.AgentRun.transition_changeset("running", 1)
        |> Repo.update()

      {:ok, failed} =
        running
        |> SddOrchestrator.Delivery.AgentRun.transition_changeset(
          "failed",
          running.state_version,
          failure_reason: "transport_lost"
        )
        |> Repo.update()

      {:ok, stopped} =
        feature |> Feature.status_changeset("failed", feature.state_version) |> Repo.update()

      DeliveryFixtures.activity_fixture(project, feature, %{
        run_id: run.id,
        attempt_id: attempt.id,
        type: "run_started",
        payload: %{"branch" => run.branch}
      })

      %{feature: stopped, run: failed, attempt: attempt}
    end

    test "shows the visible failed status with its reason", %{
      conn: conn,
      project: project,
      feature: feature,
      run: run,
      account: account
    } do
      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(feature_path(project, feature))

      assert view |> element("[data-feature-status]") |> render() =~ "Failed"
      assert view |> element("[data-feature-column]") |> render() =~ "In development"

      assert view |> element("[data-failed-reason]") |> render() =~
               "The connection to the worker was lost."

      assert view |> element("[data-failed-branch]") |> render() =~ run.branch
    end

    test "any current participant is offered the retry action", %{
      conn: conn,
      context: context,
      project: project,
      feature: feature
    } do
      # Not the initiator and not the owner: a stopped run is shared work.
      {:ok, view, _html} =
        conn
        |> log_in_hosted(context.identity.hosted_identity)
        |> live(feature_path(project, feature))

      assert has_element?(view, "[data-retry-run]")
    end

    test "retrying continues the same run without leaving development", %{
      conn: conn,
      project: project,
      feature: feature,
      run: run,
      account: account
    } do
      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(feature_path(project, feature))

      view |> element("[data-retry-run]") |> render_click()

      # The stopped panel clears, the feature keeps its column, and the run is
      # the same one on the same branch.
      refute has_element?(view, "[data-failed-run]")
      assert view |> element("[data-feature-column]") |> render() =~ "In development"

      stored = Repo.get!(SddOrchestrator.Delivery.AgentRun, run.id)

      assert stored.state == "running"
      assert stored.branch == run.branch
      assert Repo.get!(Feature, feature.id).status == "none"
      assert Repo.get!(Feature, feature.id).lifecycle_column == "in_development"
    end

    test "a feature with no failed run shows no retry action", %{
      conn: conn,
      project: project,
      account: account
    } do
      other = DeliveryFixtures.feature_fixture(project, account)

      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(feature_path(project, other))

      refute has_element?(view, "[data-failed-run]")
      refute has_element?(view, "[data-retry-run]")
    end
  end

  describe "canceling a run [AC-32]" do
    setup %{project: project, account: account} do
      feature = project |> DeliveryFixtures.feature_fixture(account) |> in_development()
      run = DeliveryFixtures.run_fixture(project, feature, %{initiator_account_id: account.id})
      attempt = DeliveryFixtures.attempt_fixture(run, %{fence_token: 1})

      {:ok, running} =
        run
        |> SddOrchestrator.Delivery.AgentRun.transition_changeset("running", run.state_version)
        |> Repo.update()

      DeliveryFixtures.activity_fixture(project, feature, %{
        run_id: run.id,
        attempt_id: attempt.id,
        type: "run_started",
        payload: %{"branch" => run.branch}
      })

      %{feature: feature, run: running, attempt: attempt}
    end

    test "the initiator is offered the action and the run's branch", %{
      conn: conn,
      project: project,
      feature: feature,
      run: run,
      account: account
    } do
      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(feature_path(project, feature))

      assert has_element?(view, "[data-cancel-run]")
      assert view |> element("[data-run-branch]") |> render() =~ run.branch
    end

    test "another current participant is not offered it", %{
      conn: conn,
      context: context,
      project: project,
      feature: feature
    } do
      # Neither the initiator nor the owner: cancelling is narrower than the
      # shared actions this screen offers everyone.
      {:ok, view, _html} =
        conn
        |> log_in_hosted(context.identity.hosted_identity)
        |> live(feature_path(project, feature))

      assert has_element?(view, "[data-screen=\"feature-detail\"]")
      refute has_element?(view, "[data-cancel-run]")
    end

    test "canceling ends the run and queues the worker's stop", %{
      conn: conn,
      project: project,
      feature: feature,
      run: run,
      account: account
    } do
      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(feature_path(project, feature))

      view |> element("[data-cancel-run]") |> render_click()

      # Terminal, so the action it came from is gone rather than repeatable.
      refute has_element?(view, "[data-cancel-run]")

      assert Repo.get!(SddOrchestrator.Delivery.AgentRun, run.id).state == "canceled"

      assert SddOrchestrator.Delivery.RunCommand
             |> Repo.all()
             |> Enum.count(&(&1.operation == "cancel")) == 1

      # This screen's project has no readiness verdict, so the feature goes back
      # to where its requirements actually leave it.
      assert view |> element("[data-feature-column]") |> render() =~ "Draft"
      assert Repo.get!(Feature, feature.id).lifecycle_column == "draft"
    end

    test "a feature with no run shows no cancel action", %{
      conn: conn,
      project: project,
      account: account
    } do
      other = DeliveryFixtures.feature_fixture(project, account)

      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(feature_path(project, other))

      refute has_element?(view, "[data-run-control]")
      refute has_element?(view, "[data-cancel-run]")
    end
  end

  defp ask(project, feature, run, attrs) do
    %BlockingQuestion{}
    |> BlockingQuestion.ask_changeset(
      Map.merge(
        %{
          project_id: project.id,
          feature_id: feature.id,
          run_id: run.id,
          branch: run.branch,
          workspace_path: "/var/sdd/workspaces/#{run.id}"
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp feature_path(project, feature), do: ~p"/projects/#{project.id}/features/#{feature.id}"

  defp log_in_hosted(conn, hosted_identity) do
    {:ok, _session, cookie} = Sessions.create(hosted_identity, %{})

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(SessionCookie.session_key(), cookie.value)
  end
end
