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

  alias SddOrchestrator.Delivery.{
    Activity,
    ArtifactStore,
    Assignment,
    BlockingQuestion,
    DeliveryStore,
    EvidencePresentation,
    Feature,
    Review,
    ReviewDecision,
    ReviewHandoff
  }

  alias SddOrchestrator.Delivery.VerificationCompletion.Verdict
  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.EvidencePresentationFixtures, as: EvidenceFixtures
  alias SddOrchestrator.HostedAccess.{SessionCookie, Sessions}
  alias SddOrchestrator.Participation
  alias SddOrchestrator.Participation.Revocations
  alias SddOrchestrator.ParticipationDeliveryDouble
  alias SddOrchestrator.PreviewPresentationFixtures, as: PreviewFixtures
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

  describe "feature activity [AC-16]" do
    test "shows normalized progress in authoritative order without changing comments", %{
      conn: conn,
      project: project,
      feature: feature,
      account: account
    } do
      for {summary, sequence} <- [{"Prepared the implementation", 7}, {"Ran focused tests", 8}] do
        assert {:ok, _entry} =
                 Activity.append(%{
                   project_id: project.id,
                   feature_id: feature.id,
                   actor_kind: "agent",
                   type: "progress",
                   payload: %{
                     "attempt_number" => 1,
                     "event_type" => "progress",
                     "sequence" => sequence,
                     "source" => "agent",
                     "summary" => summary
                   }
                 })
      end

      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(feature_path(project, feature))

      assert has_element?(view, "[data-activity][aria-labelledby=activity-heading]")
      assert has_element?(view, "#activity-heading", "Feature activity")

      assert view
             |> element("[data-activity-entry]:nth-child(1) [data-activity-summary]")
             |> render() =~ "Prepared the implementation"

      assert view
             |> element("[data-activity-entry]:nth-child(2) [data-activity-summary]")
             |> render() =~ "Ran focused tests"

      assert view |> element("[data-activity-position]", "Attempt 1, update 7") |> render()
      refute has_element?(view, "[data-activity-entry]:nth-child(3)")
      assert has_element?(view, "[data-comments-empty]")
      refute has_element?(view, "[data-comment]")
    end

    test "states when no progress has been recorded", %{
      conn: conn,
      project: project,
      feature: feature,
      account: account
    } do
      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(feature_path(project, feature))

      assert has_element?(view, "[data-activity-empty]")
      refute has_element?(view, "[data-activity-entry]")
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

  describe "the verification evidence [AC-40]" do
    setup %{project: project, account: account, context: context} do
      feature = project |> DeliveryFixtures.feature_fixture(account) |> in_development()
      run = EvidenceFixtures.run_fixture(context.workspace, project, feature)

      %{feature: feature, run: run, authority: context.workspace}
    end

    test "a feature that has proved nothing says so", %{
      conn: conn,
      project: project,
      feature: feature,
      account: account
    } do
      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(feature_path(project, feature))

      assert has_element?(view, "[data-evidence]")
      assert has_element?(view, "[data-evidence-empty]")
      refute has_element?(view, "[data-evidence-item]")
    end

    test "each recorded outcome renders as its own distinguishable state", %{
      conn: conn,
      project: project,
      feature: feature,
      account: account,
      authority: authority,
      run: run
    } do
      for {name, outcome} <- [
            {"mix test", "passed"},
            {"mix credo", "failed"},
            {"mix dialyzer", "missing"},
            {"mix sobelow", "unsupported"}
          ] do
        EvidenceFixtures.evidence_fixture(authority, run,
          name: name,
          outcome: outcome,
          exit_code: if(outcome == "passed", do: 0, else: 1)
        )
      end

      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(feature_path(project, feature))

      refute has_element?(view, "[data-evidence-empty]")

      for {name, outcome, label} <- [
            {"mix test", "passed", "Passed"},
            {"mix credo", "failed", "Failed"},
            {"mix dialyzer", "missing", "Missing"},
            {"mix sobelow", "unsupported", "Unsupported"}
          ] do
        item = "[data-evidence-item][data-evidence-state=\"#{outcome}\"]"

        assert view |> element("#{item} [data-evidence-name]") |> render() =~ name
        assert view |> element("#{item} [data-evidence-state-label]") |> render() =~ label
        assert view |> element("#{item} [data-evidence-type]") |> render() =~ "Required check"
      end
    end

    test "a negative state is not carried by colour alone", %{
      conn: conn,
      project: project,
      feature: feature,
      account: account,
      authority: authority,
      run: run
    } do
      for outcome <- ~w(failed missing) do
        EvidenceFixtures.evidence_fixture(authority, run,
          name: "mix #{outcome}",
          outcome: outcome,
          exit_code: 1
        )
      end

      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(feature_path(project, feature))

      for outcome <- ~w(failed missing) do
        badge =
          view
          |> element("[data-evidence-state=\"#{outcome}\"] [data-evidence-state-label]")
          |> render()

        # An error-red pill that also carries an icon and a word, so the state
        # survives a reader who cannot tell the colours apart.
        assert badge =~ "text-err-fg"
        assert badge =~ "<svg"
      end
    end

    test "every item shows the provenance it was recorded with", %{
      conn: conn,
      project: project,
      feature: feature,
      account: account,
      authority: authority,
      run: run
    } do
      evidence =
        EvidenceFixtures.evidence_fixture(authority, run,
          name: "mix test",
          source: "worker",
          duration_ms: 12_500,
          redacted: true,
          recorded_at: ~U[2026-07-30 09:15:00.000000Z]
        )

      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(feature_path(project, feature))

      item = "[data-evidence-item]"

      assert fact(view, item, "attempt") =~
               EvidencePresentation.short_reference(run.attempt.id)

      assert fact(view, item, "run") =~ EvidencePresentation.short_reference(run.run.id)
      assert fact(view, item, "branch") =~ run.run.branch
      assert fact(view, item, "commit") =~ EvidenceFixtures.commit()
      assert fact(view, item, "source") =~ "The worker that ran it"
      assert fact(view, item, "recorded") =~ "2026-07-30 09:15 UTC"
      assert fact(view, item, "duration") =~ "12.5 s"
      assert fact(view, item, "digest") =~ evidence.digest
      assert fact(view, item, "redaction") =~ "Redacted"
      assert fact(view, item, "command") =~ "mix test"
      assert fact(view, item, "exit-code") =~ "0"
    end

    test "a replaced result stays visible and names its replacement", %{
      conn: conn,
      project: project,
      feature: feature,
      account: account,
      authority: authority,
      run: run
    } do
      failed =
        EvidenceFixtures.evidence_fixture(authority, run,
          name: "mix test",
          outcome: "failed",
          exit_code: 1
        )

      passed = EvidenceFixtures.evidence_fixture(authority, run, name: "mix test")
      :ok = EvidenceFixtures.supersede_fixture(authority, failed, passed)

      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(feature_path(project, feature))

      # Both are on the screen: the replaced result is not filtered away, and it
      # keeps the failure it recorded rather than inheriting the rerun's pass.
      assert view |> render() |> then(&Regex.scan(~r/data-evidence-item/, &1)) |> length() == 2

      replaced = "[data-evidence-item][data-evidence-superseded=\"true\"]"

      assert has_element?(view, replaced)

      assert view |> element("#{replaced}[data-evidence-state=\"failed\"]") |> render() =~
               "Failed"

      assert view |> element("#{replaced} [data-evidence-superseded-label]") |> render() =~
               "Replaced"

      assert view |> element("#{replaced} [data-evidence-replacement]") |> render() =~
               EvidencePresentation.short_reference(passed.id)

      assert has_element?(view, "[data-evidence-item][data-evidence-superseded=\"false\"]")
    end

    test "a refused verification names the checks behind the refusal", %{
      conn: conn,
      project: project,
      feature: feature,
      account: account,
      authority: authority,
      run: run
    } do
      EvidenceFixtures.verdict_fixture(
        authority,
        run,
        EvidenceFixtures.refused_verdict(run,
          reason: :required_check_failed,
          required: ["mix test", "mix credo", "mix dialyzer"],
          passed: ["mix test"],
          failed: ["mix credo"],
          missing: ["mix dialyzer"]
        )
      )

      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(feature_path(project, feature))

      assert view |> element("[data-verification]") |> render() =~ "data-verification-outcome"
      assert view |> element("[data-verification-label]") |> render() =~ "Not verified"

      assert view |> element("[data-verification-reason]") |> render() =~
               "A required check failed"

      assert view |> element("[data-verification-counts]") |> render() =~ "1 of 3"

      assert view
             |> element("[data-verification] [data-evidence-fact=\"verification-failed\"]")
             |> render() =~ "mix credo"

      assert view
             |> element("[data-verification] [data-evidence-fact=\"verification-missing\"]")
             |> render() =~ "mix dialyzer"
    end

    test "a verified completion is shown as verified", %{
      conn: conn,
      project: project,
      feature: feature,
      account: account,
      authority: authority,
      run: run
    } do
      EvidenceFixtures.verdict_fixture(authority, run, %Verdict{
        outcome: :verified,
        run_id: run.run.id,
        attempt_id: run.attempt.id,
        attempt_number: 1,
        branch: run.run.branch,
        commit_sha: EvidenceFixtures.commit(),
        required: ["mix test"],
        passed: ["mix test"]
      })

      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(feature_path(project, feature))

      assert view |> element("[data-verification]") |> render() =~ "verified"
      assert view |> element("[data-verification-label]") |> render() =~ "Verified"
      refute has_element?(view, "[data-verification-reason]")
    end

    test "a stored screenshot is shown to a participant without ever being addressable", %{
      conn: conn,
      project: project,
      feature: feature,
      account: account,
      authority: authority,
      run: run
    } do
      content = DeliveryFixtures.png_bytes("detail")

      EvidenceFixtures.screenshot_fixture(authority, run,
        name: "feature screen",
        content: content
      )

      {:ok, view, html} =
        conn |> log_in_account(account) |> live(feature_path(project, feature))

      assert view
             |> element("[data-evidence-item][data-evidence-kind=\"screenshot\"]")
             |> render() =~
               "Screenshot"

      assert view |> element("[data-evidence-fact=\"artifact\"]") |> render() =~ "image/png"

      # The list itself carries no reference and no way to reach the bytes.
      refute html =~ ArtifactStore.ref_prefix()
      refute has_element?(view, "[data-evidence-artifact]")

      view |> element("[data-view-evidence]") |> render_click()

      shown = view |> element("[data-evidence-artifact]") |> render()

      assert shown =~ "data:image/png;base64,#{Base.encode64(content)}"
      assert shown =~ "alt="
      refute shown =~ ArtifactStore.ref_prefix()
      refute view |> render() =~ ArtifactStore.ref_prefix()

      view |> element("[data-hide-evidence]") |> render_click()
      refute has_element?(view, "[data-evidence-artifact]")
    end

    test "an item that never held bytes offers nothing to view and refuses the request", %{
      conn: conn,
      project: project,
      feature: feature,
      account: account,
      authority: authority,
      run: run
    } do
      evidence = EvidenceFixtures.evidence_fixture(authority, run, name: "mix test")

      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(feature_path(project, feature))

      refute has_element?(view, "[data-view-evidence]")

      # A pushed request is answered by the server rather than by the absence of
      # a button, because the button is only a suggestion.
      render_click(view, "view_evidence", %{"id" => evidence.id})

      assert view |> element("[data-evidence-artifact-error]") |> render() =~
               "That proof is not available."

      refute has_element?(view, "[data-evidence-artifact]")
    end

    test "another project's item is refused in exactly the same words", %{
      conn: conn,
      project: project,
      feature: feature,
      account: account,
      authority: authority,
      run: run
    } do
      EvidenceFixtures.evidence_fixture(authority, run, name: "mix test")

      other = DeliveryFixtures.delivery_project_fixture()
      other_feature = DeliveryFixtures.feature_fixture(other.project, other.account)
      other_run = EvidenceFixtures.run_fixture(other.workspace, other.project, other_feature)

      theirs =
        EvidenceFixtures.screenshot_fixture(other.workspace, other_run, name: "their screen")

      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(feature_path(project, feature))

      render_click(view, "view_evidence", %{"id" => theirs.id})

      assert view |> element("[data-evidence-artifact-error]") |> render() =~
               "That proof is not available."

      refute view |> render() =~ "their screen"
    end

    test "a participant who has left loses the bytes on the next request", %{
      conn: conn,
      context: context,
      project: project,
      feature: feature,
      account: account,
      authority: authority,
      run: run
    } do
      evidence = EvidenceFixtures.screenshot_fixture(authority, run, name: "feature screen")

      {:ok, view, _html} =
        conn
        |> log_in_hosted(context.identity.hosted_identity)
        |> live(feature_path(project, feature))

      view |> element("[data-view-evidence]") |> render_click()
      assert has_element?(view, "[data-evidence-artifact]")

      {:ok, _removed} =
        Revocations.remove(project, account.id, context.identity.hosted_identity.id)

      render_click(view, "view_evidence", %{"id" => evidence.id})

      assert view |> element("[data-evidence-artifact-error]") |> render() =~
               "That proof is not available."

      refute has_element?(view, "[data-evidence-artifact]")
    end

    test "no participant's address appears anywhere on the evidence screen", %{
      conn: conn,
      project: project,
      feature: feature,
      account: account,
      authority: authority,
      run: run
    } do
      EvidenceFixtures.evidence_fixture(authority, run, name: "mix test")
      EvidenceFixtures.screenshot_fixture(authority, run, name: "feature screen")

      EvidenceFixtures.verdict_fixture(
        authority,
        run,
        EvidenceFixtures.refused_verdict(run, required: ["mix test"], failed: ["mix test"])
      )

      {:ok, view, html} =
        conn |> log_in_account(account) |> live(feature_path(project, feature))

      refute html =~ "@example.com"
      view |> element("[data-view-evidence]") |> render_click()
      refute view |> render() =~ "@example.com"
    end

    test "the evidence section labels itself for a screen reader", %{
      conn: conn,
      project: project,
      feature: feature,
      account: account,
      authority: authority,
      run: run
    } do
      EvidenceFixtures.evidence_fixture(authority, run, name: "mix test")

      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(feature_path(project, feature))

      section = view |> element("[data-evidence]") |> render()

      assert section =~ "aria-labelledby=\"evidence-heading\""
      assert section =~ "id=\"evidence-heading\""
      assert section =~ "Verification evidence"

      # The control a keyboard user reaches is a real button, not a clickable div.
      assert view |> element("[data-evidence] h3[data-evidence-name]") |> render() =~ "mix test"
    end
  end

  describe "the ready-for-review handoff [AC-23]" do
    setup %{project: project, account: account, context: context} do
      feature = project |> DeliveryFixtures.feature_fixture(account) |> in_development()

      %{feature: feature, run: proven_run(context.workspace, project, feature)}
    end

    test "a feature still in development offers no review handoff", %{
      conn: conn,
      project: project,
      feature: feature,
      account: account
    } do
      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(feature_path(project, feature))

      assert view |> element("[data-feature-column]") |> render() =~ "In development"
      refute has_element?(view, "[data-review-handoff]")
    end

    test "a verified run shows the review state and who it waits on [AC-23]", %{
      conn: conn,
      context: context,
      project: project,
      feature: feature,
      account: account,
      run: run
    } do
      owner_label = Participation.owner_profile(project.id).display_name

      {:ok, %{applied?: true}} = ReviewHandoff.deliver(context.workspace, project.id, run.run)

      {:ok, view, html} =
        conn |> log_in_account(account) |> live(feature_path(project, feature))

      assert view |> element("[data-feature-column]") |> render() =~ "Ready for review"
      assert has_element?(view, "[data-review-handoff]")
      assert view |> element("[data-review-responsible]") |> render() =~ owner_label
      assert view |> element("[data-review-branch]") |> render() =~ run.run.branch
      assert view |> element("[data-review-commit]") |> render() =~ EvidenceFixtures.commit()

      # What the run itself achieved is `Ready for review` and nothing further.
      # This deliberately checks the column rather than the whole page: since
      # Task 34 the owner reading this screen *is* offered a way to finish the
      # feature, so refuting the word "Done" anywhere in the markup would stop
      # testing the handoff and start dictating what the approve control may be
      # called.
      refute view |> element("[data-feature-column]") |> render() =~ "Done"
      refute html =~ "@example.com"
      refute html =~ context.identity.hosted_identity.id
    end

    test "the current assignee is the person the review waits on", %{
      conn: conn,
      context: context,
      project: project,
      feature: feature,
      account: account,
      run: run
    } do
      target = context.identity.account
      assignee_label = Participation.member_profile(project.id, target.id).display_name

      {:ok, _assigned} =
        Assignment.assign(project.id, context.owner_actor, feature, target.id)

      {:ok, %{applied?: true}} = ReviewHandoff.deliver(context.workspace, project.id, run.run)

      {:ok, view, html} =
        conn |> log_in_account(account) |> live(feature_path(project, feature))

      responsible = view |> element("[data-review-responsible]") |> render()

      assert responsible =~ assignee_label
      refute responsible =~ Participation.owner_profile(project.id).display_name
      refute html =~ "@example.com"
    end

    test "the review section labels itself for a screen reader", %{
      conn: conn,
      context: context,
      project: project,
      feature: feature,
      account: account,
      run: run
    } do
      {:ok, %{applied?: true}} = ReviewHandoff.deliver(context.workspace, project.id, run.run)

      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(feature_path(project, feature))

      section = view |> element("[data-review-handoff]") |> render()

      assert section =~ "aria-labelledby=\"review-handoff-heading\""
      assert section =~ "id=\"review-handoff-heading\""
      assert section =~ "Ready for review"

      # The state is not carried by colour alone: it has an icon and a word.
      assert section =~ "<svg"
    end
  end

  # The final product decision, on the screen it is made from. Two people may
  # make it — whoever responsibility currently resolves to, and the project owner
  # — and the screen offers the controls to nobody else, because a control whose
  # press the domain would refuse must never appear [AC-24]. An approval is the
  # one move that finishes a feature [AC-25].
  describe "deciding the review [AC-24, AC-25]" do
    setup %{project: project, account: account, context: context} do
      # A rejection plans the next attempt's manifest in the same commit as its
      # verdict, so this block is configured with the same execution boundary a
      # run is started from. Without it a rejection would raise, and the screen
      # would be proved against a crash rather than against the domain.
      configure_execution()

      feature = project |> DeliveryFixtures.feature_fixture(account) |> in_development()
      run = proven_run(context.workspace, project, feature)

      {:ok, %{applied?: true}} = ReviewHandoff.deliver(context.workspace, project.id, run.run)

      %{feature: Repo.get!(Feature, feature.id), run: run}
    end

    test "the current responsible participant approves and the feature is finished [AC-25]", %{
      conn: conn,
      context: context,
      project: project,
      feature: feature
    } do
      target = context.identity.account
      {:ok, _assigned} = Assignment.assign(project.id, context.owner_actor, feature, target.id)
      label = Participation.member_profile(project.id, target.id).display_name

      {:ok, view, _html} =
        conn
        |> log_in_hosted(context.identity.hosted_identity)
        |> live(feature_path(project, feature))

      assert has_element?(view, "[data-review-approve]")
      assert has_element?(view, "[data-review-reject]")

      view |> element("[data-review-approve]") |> render_click()

      assert view |> element("[data-feature-column]") |> render() =~ "Done"
      assert Repo.get!(Feature, feature.id).lifecycle_column == "done"

      assert has_element?(
               view,
               "[data-review-decision][data-review-decision-outcome=\"approved\"]"
             )

      assert view |> element("[data-review-decision-label]") |> render() =~ "Approved"
      assert view |> element("[data-review-decision-reviewer]") |> render() =~ label

      # An approval carries no feedback at all, and the feature is finished, so
      # there is nothing left on this screen to decide.
      refute has_element?(view, "[data-review-decision-feedback]")
      refute has_element?(view, "[data-review-approve]")
      refute has_element?(view, "[data-review-reject]")
    end

    test "the project owner decides work somebody else is responsible for [AC-25]", %{
      conn: conn,
      context: context,
      project: project,
      feature: feature,
      account: account
    } do
      target = context.identity.account
      {:ok, _assigned} = Assignment.assign(project.id, context.owner_actor, feature, target.id)
      owner_label = Participation.owner_profile(project.id).display_name

      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(feature_path(project, feature))

      # The owner is deliberately not the person the review waits on. They may
      # still decide, so a departure cannot strand a feature nobody can finish.
      assert view |> element("[data-review-responsible]") |> render() =~
               Participation.member_profile(project.id, target.id).display_name

      assert has_element?(view, "[data-review-approve]")
      assert has_element?(view, "[data-review-reject]")

      view |> element("[data-review-approve]") |> render_click()

      assert view |> element("[data-feature-column]") |> render() =~ "Done"
      assert view |> element("[data-review-decision-reviewer]") |> render() =~ owner_label
    end

    test "another current participant is offered no way to decide [AC-24]", %{
      conn: conn,
      context: context,
      project: project,
      feature: feature,
      run: run
    } do
      # Nobody is assigned, so responsibility resolves to the creator, who is the
      # owner. This participant is neither, which is exactly the person AC-24 is
      # about: entitled to read the feature, not to end it.
      {:ok, view, _html} =
        conn
        |> log_in_hosted(context.identity.hosted_identity)
        |> live(feature_path(project, feature))

      assert has_element?(view, "[data-review-handoff]")
      assert view |> element("[data-review-branch]") |> render() =~ run.run.branch
      assert view |> element("[data-review-commit]") |> render() =~ EvidenceFixtures.commit()

      refute has_element?(view, "[data-review-controls]")
      refute has_element?(view, "[data-review-approve]")
      refute has_element?(view, "[data-review-reject]")
      refute has_element?(view, "[data-review-feedback]")
    end

    test "a forged decision from another participant is refused and changes nothing [AC-24]", %{
      conn: conn,
      context: context,
      project: project,
      feature: feature
    } do
      before = Repo.get!(Feature, feature.id)

      {:ok, approving, _html} =
        conn
        |> log_in_hosted(context.identity.hosted_identity)
        |> live(feature_path(project, feature))

      # The control is absent, so the only way to reach the action is to send the
      # event without it. The domain refuses, and the screen answers the way it
      # answers every unauthorized action rather than explaining the refusal.
      render_click(approving, "approve")
      assert_redirect(approving, ~p"/projects")

      {:ok, rejecting, _html} =
        conn
        |> log_in_hosted(context.identity.hosted_identity)
        |> live(feature_path(project, feature))

      render_submit(rejecting, "reject", %{"review" => %{"feedback" => "Not for me to say"}})
      assert_redirect(rejecting, ~p"/projects")

      assert Repo.get!(Feature, feature.id) == before
      assert Review.decision(context.workspace, project.id, before) == nil
    end

    test "a rejection with nothing to act on is refused inline and writes nothing", %{
      conn: conn,
      context: context,
      project: project,
      feature: feature,
      account: account
    } do
      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(feature_path(project, feature))

      for blank <- ["", "   \n  "] do
        view |> form("#review-form", %{"review" => %{"feedback" => blank}}) |> render_submit()

        assert view |> element("[data-review-error]") |> render() =~ "what needs to change"
        refute has_element?(view, "[data-review-decision]")
        assert Review.decision(context.workspace, project.id, feature) == nil
        assert Repo.get!(Feature, feature.id).lifecycle_column == "ready_for_review"
      end
    end

    test "a recorded rejection is readable in full and sends the work back", %{
      conn: conn,
      context: context,
      project: project,
      feature: feature,
      account: account
    } do
      # Longer than the bounded excerpt the activity payload carries, so a screen
      # rendering the excerpt instead of the decision record would lose the tail.
      tail = "Finally, the empty state still shows a spinner."
      feedback = String.duplicate("There is a lot to say about this attempt. ", 12) <> tail

      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(feature_path(project, feature))

      view |> form("#review-form", %{"review" => %{"feedback" => feedback}}) |> render_submit()

      assert has_element?(
               view,
               "[data-review-decision][data-review-decision-outcome=\"rejected\"]"
             )

      assert view |> element("[data-review-decision-label]") |> render() =~ "Sent back"

      recorded = view |> element("[data-review-decision-feedback]") |> render()
      assert recorded =~ tail
      assert recorded =~ "There is a lot to say about this attempt."
      assert Review.decision(context.workspace, project.id, feature).feedback == feedback

      # The verdict is recorded and the work goes back in one move: the feature
      # returns to `In development` and the screen says the run continues from
      # the feedback rather than leaving it where it was.
      assert view |> element("[data-feature-column]") |> render() =~ "In development"
      assert Repo.get!(Feature, feature.id).lifecycle_column == "in_development"
      assert view |> element("[data-review-decision-note]") |> render() =~ "back in development"
      refute has_element?(view, "[data-review-error]")
    end

    test "the recorded verdict names the branch and commit that were verified", %{
      conn: conn,
      project: project,
      feature: feature,
      account: account,
      run: run
    } do
      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(feature_path(project, feature))

      view |> element("[data-review-approve]") |> render_click()

      assert view |> element("[data-review-decision-branch]") |> render() =~ run.run.branch

      assert view |> element("[data-review-decision-commit]") |> render() =~
               EvidenceFixtures.commit()
    end

    test "a reviewer who has left is named the way this screen names every former member", %{
      conn: conn,
      context: context,
      project: project,
      feature: feature,
      account: account
    } do
      target = context.identity.account
      {:ok, _assigned} = Assignment.assign(project.id, context.owner_actor, feature, target.id)
      label = Participation.member_profile(project.id, target.id).display_name

      {:ok, deciding, _html} =
        conn
        |> log_in_hosted(context.identity.hosted_identity)
        |> live(feature_path(project, feature))

      deciding |> element("[data-review-approve]") |> render_click()

      {:ok, _removed} =
        Revocations.remove(project, account.id, context.identity.hosted_identity.id)

      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(feature_path(project, feature))

      # The display name resolves from current participation, so a departure is
      # reflected rather than frozen — and no name is invented in its place.
      reviewer = view |> element("[data-review-decision-reviewer]") |> render()

      assert reviewer =~ "A former member"
      refute reviewer =~ label
    end

    test "no participant address reaches the review section", %{
      conn: conn,
      context: context,
      project: project,
      feature: feature,
      account: account
    } do
      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(feature_path(project, feature))

      view
      |> form("#review-form", %{"review" => %{"feedback" => "Contact nobody about this"}})
      |> render_submit()

      section = view |> element("[data-review-handoff]") |> render()

      refute section =~ "@example.com"
      refute section =~ context.identity.hosted_identity.id
      refute section =~ account.id
      refute view |> render() =~ "@example.com"
    end

    test "the decision controls label themselves for a screen reader", %{
      conn: conn,
      project: project,
      feature: feature,
      account: account
    } do
      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(feature_path(project, feature))

      section = view |> element("[data-review-handoff]") |> render()

      assert section =~ "aria-labelledby=\"review-handoff-heading\""
      assert section =~ "id=\"review-handoff-heading\""

      # The feedback field is a real labelled control, and the rule it is bound
      # by is the domain's own limit rather than a second one written here.
      assert section =~ "for=\"review-feedback\""
      assert section =~ "id=\"review-feedback\""
      assert section =~ "maxlength=\"#{ReviewDecision.max_feedback_bytes()}\""

      view |> form("#review-form", %{"review" => %{"feedback" => ""}}) |> render_submit()

      decided = view |> element("[data-review-handoff]") |> render()

      assert decided =~ "aria-invalid=\"true\""
      assert decided =~ "aria-describedby=\"review-feedback-error\""
    end
  end

  # Sending work back is not where the review ends. The feature returns to
  # `In development`, the same run continues on the same branch as one further
  # attempt, and everything the earlier attempts proved is still readable
  # [AC-26, AC-35].
  #
  # Whether acting on the feedback would change the approved product agreement is
  # the reviewer's own declaration, never something read out of what they wrote.
  # So both outcomes are driven from the control rather than from the words, and
  # a declared contradiction opens a question for the specification instead of
  # sending the agent back to work against an agreement that no longer holds.
  describe "continuing rejected work [AC-26, AC-35]" do
    setup %{project: project, account: account, context: context} do
      configure_execution()
      configure_workspace_root()

      feature = project |> DeliveryFixtures.feature_fixture(account) |> in_development()
      run = proven_run(context.workspace, project, feature)

      {:ok, %{applied?: true}} = ReviewHandoff.deliver(context.workspace, project.id, run.run)

      %{feature: Repo.get!(Feature, feature.id), run: run}
    end

    test "an ordinary rejection returns the feature to development on screen [AC-26]", %{
      conn: conn,
      context: context,
      project: project,
      feature: feature,
      run: run,
      account: account
    } do
      feedback = "The empty state still shows a spinner after the first load."

      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(feature_path(project, feature))

      view |> form("#review-form", %{"review" => %{"feedback" => feedback}}) |> render_submit()

      assert view |> element("[data-feature-column]") |> render() =~ "In development"

      # Back at work rather than paused: no visible status, and nothing waiting
      # on a person.
      refute has_element?(view, "[data-feature-status]")
      refute has_element?(view, "[data-blocking-question]")

      # The verdict does not leave with the column it was made from. Whoever has
      # to act on it must still be able to read the whole thing.
      assert view |> element("[data-review-decision-feedback]") |> render() =~ feedback
      assert view |> element("[data-review-decision-branch]") |> render() =~ run.run.branch

      assert has_element?(
               view,
               "[data-review-decision-note][data-review-decision-continuation=\"continued\"]"
             )

      assert view |> element("[data-review-decision-note]") |> render() =~ "same run continues"

      stored = Repo.get!(Feature, feature.id)
      assert stored.lifecycle_column == "in_development"
      assert stored.status == "none"

      # The same run on the same branch, with one further ordered attempt built
      # from the feedback rather than a second run started beside it [AC-35].
      continued = Repo.get!(SddOrchestrator.Delivery.AgentRun, run.run.id)
      assert continued.branch == run.run.branch

      {:ok, next} = DeliveryStore.latest_attempt(context.workspace, project.id, run.run.id)

      assert next.attempt_number == run.attempt.attempt_number + 1
      assert next.continuation_reason == "review_feedback"
    end

    # The continued run is free to block on a question of the agent's own, which
    # makes the feature `Blocked` for a reason that has nothing to do with the
    # review. The note must still say the work was sent back to the agent, or it
    # tells the reviewer their words paused a run they in fact restarted. This is
    # why the outcome is read from the flag the rejection recorded rather than
    # from the feature's status or from the question's text.
    test "an agent's own later question does not restate the rejection as blocked", %{
      conn: conn,
      project: project,
      feature: feature,
      run: run,
      account: account
    } do
      feedback = "The empty state still shows a spinner after the first load."

      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(feature_path(project, feature))

      view |> form("#review-form", %{"review" => %{"feedback" => feedback}}) |> render_submit()

      # The agent picks the work back up and then asks about something else
      # entirely.
      ask(project, feature, run.run, %{
        question: "Which currency should the totals use?",
        context: "The design names no currency."
      })

      {:ok, blocked_view, _html} =
        conn |> log_in_account(account) |> live(feature_path(project, feature))

      assert has_element?(blocked_view, "[data-blocking-question]")

      assert has_element?(
               blocked_view,
               "[data-review-decision-note][data-review-decision-continuation=\"continued\"]"
             )

      refute blocked_view |> element("[data-review-decision-note]") |> render() =~
               "Nothing was sent"
    end

    test "a declared contradiction blocks for the specification instead [AC-26]", %{
      conn: conn,
      project: project,
      feature: feature,
      run: run,
      account: account
    } do
      feedback = "Guests should never reach this screen at all."

      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(feature_path(project, feature))

      view
      |> form("#review-form", %{
        "review" => %{"feedback" => feedback, "contradicts_agreement" => "true"}
      })
      |> render_submit()

      # Blocked is a status, so the work still went back to `In development`
      # rather than to a column of its own.
      assert view |> element("[data-feature-column]") |> render() =~ "In development"
      assert view |> element("[data-feature-status]") |> render() =~ "Blocked"

      # The question a participant raised renders in the section this screen
      # already has, carrying the reviewer's own words and saying what answering
      # will do. Nothing about the section assumes an agent asked it.
      assert has_element?(view, "[data-blocking-question]")
      assert view |> element("[data-question-text]") |> render() =~ feedback

      assert view |> element("[data-question-context]") |> render() =~
               "changes the approved product agreement"

      assert view |> element("[data-question-branch]") |> render() =~ run.run.branch
      assert has_element?(view, "[data-answer-form]")

      assert has_element?(
               view,
               "[data-review-decision-note][data-review-decision-continuation=\"blocked\"]"
             )

      assert view |> element("[data-review-decision-note]") |> render() =~
               "paused on the question"

      stored = Repo.get!(Feature, feature.id)
      assert stored.lifecycle_column == "in_development"
      assert stored.status == "blocked"
    end

    test "the declaration is off until the reviewer turns it on [AC-26]", %{
      conn: conn,
      project: project,
      feature: feature,
      account: account
    } do
      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(feature_path(project, feature))

      # The control is offered unchecked, and says what turning it on does
      # before anyone turns it on.
      assert has_element?(view, "[data-review-contradiction]")
      refute view |> element("[data-review-contradiction]") |> render() =~ "checked"

      assert view |> element("[data-review-contradiction-hint]") |> render() =~
               "raised as a question for the specification"

      # Pressing `Send back` without touching it takes the ordinary path. That is
      # what makes this a declaration rather than something the product guesses.
      view
      |> form("#review-form", %{"review" => %{"feedback" => "Tighten the empty state."}})
      |> render_submit()

      assert has_element?(
               view,
               "[data-review-decision-note][data-review-decision-continuation=\"continued\"]"
             )

      refute has_element?(view, "[data-blocking-question]")
      assert Repo.get!(Feature, feature.id).status == "none"
    end

    test "blank feedback is refused inline in either mode and writes nothing", %{
      conn: conn,
      context: context,
      project: project,
      feature: feature,
      account: account
    } do
      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(feature_path(project, feature))

      # Ordered so the declaration is only ever turned on: a refused submission
      # keeps it, which is deliberate, and a later undeclared case would inherit
      # it and stop proving what it claims to.
      attempts = [
        %{"feedback" => ""},
        %{"feedback" => "   \n  "},
        %{"feedback" => "", "contradicts_agreement" => "true"},
        %{"feedback" => "   \n  ", "contradicts_agreement" => "true"}
      ]

      for attempt <- attempts do
        view |> form("#review-form", %{"review" => attempt}) |> render_submit()

        assert view |> element("[data-review-error]") |> render() =~ "what needs to change"
        refute has_element?(view, "[data-review-decision]")
        refute has_element?(view, "[data-blocking-question]")
        assert Review.decision(context.workspace, project.id, feature) == nil

        # Nothing moved, nothing paused, and no attempt was opened for feedback
        # that says nothing.
        stored = Repo.get!(Feature, feature.id)
        assert stored.lifecycle_column == "ready_for_review"
        assert stored.status == "none"
      end
    end

    test "prior evidence is still on the screen after the work continues [AC-26]", %{
      conn: conn,
      project: project,
      feature: feature,
      run: run,
      account: account
    } do
      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(feature_path(project, feature))

      proved = view |> element("[data-evidence-item]") |> render()

      view
      |> form("#review-form", %{"review" => %{"feedback" => "Add the missing empty state."}})
      |> render_submit()

      # Preserved has to mean readable, not merely stored: the same item, whole
      # and unchanged, beside the completion that proved it.
      assert view |> element("[data-evidence-item]") |> render() == proved
      assert view |> element("[data-verification-label]") |> render() =~ "Verified"
      assert fact(view, "[data-evidence-item]", "branch") =~ run.run.branch
      refute has_element?(view, "[data-evidence-empty]")
    end

    test "no participant address reaches the review section in either mode", %{
      conn: conn,
      context: context,
      project: project,
      feature: feature,
      account: account
    } do
      # One decision per feature, so the declared mode needs a second feature
      # that reached review the same way.
      contradicted = awaiting_review(context, project, account)

      for {target, declaration} <- [
            {feature, %{}},
            {contradicted, %{"contradicts_agreement" => "true"}}
          ] do
        {:ok, view, _html} =
          conn |> log_in_account(account) |> live(feature_path(project, target))

        view
        |> form("#review-form", %{
          "review" => Map.put(declaration, "feedback", "Contact nobody about this")
        })
        |> render_submit()

        section = view |> element("[data-review-handoff]") |> render()

        refute section =~ "@example.com"
        refute section =~ context.identity.hosted_identity.id
        refute section =~ account.id
        refute view |> render() =~ "@example.com"
      end
    end
  end

  describe "the preview [AC-22]" do
    setup %{project: project, account: account, context: context} do
      feature = project |> DeliveryFixtures.feature_fixture(account) |> in_development()
      on_exit(PreviewFixtures.configure(project))

      %{feature: feature, authority: context.workspace}
    end

    test "a project with no authorized path says so and offers no link", %{
      conn: conn,
      project: project,
      feature: feature,
      account: account
    } do
      on_exit(PreviewFixtures.unconfigure())

      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(feature_path(project, feature))

      assert has_element?(view, "[data-preview][data-preview-state=\"not_configured\"]")
      assert has_element?(view, "[data-preview-unavailable]")
      refute has_element?(view, "[data-preview-list]")
      refute has_element?(view, "[data-preview-link]")
    end

    test "a configured project with nothing deployed is waiting, not missing", %{
      conn: conn,
      project: project,
      feature: feature,
      account: account
    } do
      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(feature_path(project, feature))

      assert has_element?(view, "[data-preview][data-preview-state=\"none\"]")
      assert view |> element("[data-preview-none]") |> render() =~ PreviewFixtures.path()
      refute has_element?(view, "[data-preview-unavailable]")
      refute has_element?(view, "[data-preview-link]")
    end

    test "a preview still deploying shows its state and no link", %{
      conn: conn,
      project: project,
      feature: feature,
      account: account,
      authority: authority
    } do
      PreviewFixtures.preview_fixture(authority, project, feature, :pending)

      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(feature_path(project, feature))

      assert view |> element(item("pending") <> " [data-preview-state-label]") |> render() =~
               "Deploying"

      assert has_element?(view, item("pending") <> " [data-preview-fact=\"timeout\"]")
      refute has_element?(view, "[data-preview-link]")
    end

    test "a ready preview is labelled non-production and names what produced it [AC-22]", %{
      conn: conn,
      project: project,
      feature: feature,
      account: account,
      authority: authority
    } do
      %{run: run} = PreviewFixtures.preview_fixture(authority, project, feature, :ready)

      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(feature_path(project, feature))

      link = view |> element(item("ready") <> " [data-preview-link]") |> render()

      assert link =~ "href=\"#{PreviewFixtures.link()}\""
      assert link =~ "target=\"_blank\""
      assert link =~ "rel=\"noopener noreferrer\""

      assert view |> element(item("ready") <> " [data-preview-nonproduction]") |> render() =~
               "Non-production"

      note = view |> element(item("ready") <> " [data-preview-link-note]") |> render()

      assert note =~ "non-production"
      assert note =~ run.branch
      assert note =~ PreviewFixtures.commit()
    end

    test "a provider failure states a reason and presents no link [AC-22]", %{
      conn: conn,
      project: project,
      feature: feature,
      account: account,
      authority: authority
    } do
      PreviewFixtures.preview_fixture(authority, project, feature, :failed)

      {:ok, view, html} =
        conn |> log_in_account(account) |> live(feature_path(project, feature))

      reason = view |> element(item("failed") <> " [data-preview-reason]") |> render()

      assert reason =~ "no capacity left"
      refute reason =~ "quota_exhausted"

      # The token itself stays visible as a code rather than being dressed up as
      # a sentence or hidden entirely.
      assert view |> element(item("failed") <> " [data-preview-fact=\"reason-code\"]") |> render() =~
               "quota_exhausted"

      refute has_element?(view, "[data-preview-link]")
      refute html =~ PreviewFixtures.link()
    end

    test "a timeout is presented as its own state, not as a plain failure [AC-22]", %{
      conn: conn,
      project: project,
      feature: feature,
      account: account,
      authority: authority
    } do
      PreviewFixtures.preview_fixture(authority, project, feature, :timed_out)

      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(feature_path(project, feature))

      assert view |> element(item("timed_out") <> " [data-preview-state-label]") |> render() =~
               "Timed out"

      assert view |> element(item("timed_out") <> " [data-preview-reason]") |> render() =~
               "did not answer in time"

      refute has_element?(view, "[data-preview-link]")
    end

    test "an expiry says the lifetime ran out rather than that something broke [AC-22]", %{
      conn: conn,
      project: project,
      feature: feature,
      account: account,
      authority: authority
    } do
      PreviewFixtures.preview_fixture(authority, project, feature, :expired)

      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(feature_path(project, feature))

      assert view |> element(item("expired") <> " [data-preview-state-label]") |> render() =~
               "Expired"

      assert view |> element(item("expired") <> " [data-preview-expired-note]") |> render() =~
               "Nothing failed"

      assert has_element?(view, item("expired") <> " [data-preview-fact=\"expires\"]")
      refute has_element?(view, item("expired") <> " [data-preview-reason]")
      refute has_element?(view, "[data-preview-link]")
    end

    test "a replaced preview stays visible beside the one that replaced it [AC-22]", %{
      conn: conn,
      project: project,
      feature: feature,
      account: account,
      authority: authority
    } do
      first = PreviewFixtures.preview_fixture(authority, project, feature, :ready)
      PreviewFixtures.supersede_fixture(authority, project, first)

      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(feature_path(project, feature))

      # Nothing is filtered: both deployments stay on the screen.
      assert view |> render() |> count("data-preview-item") == 2

      replaced = item("superseded")

      assert view |> element(replaced <> " [data-preview-state-label]") |> render() =~ "Replaced"
      assert view |> element(replaced <> " [data-preview-replacement]") |> render() =~ "replaced"
      assert has_element?(view, replaced <> "[data-preview-current=\"false\"]")

      # The replaced one keeps its place and loses its link; only the current
      # deployment is somewhere a reader may be sent.
      refute has_element?(view, replaced <> " [data-preview-link]")
      assert has_element?(view, item("ready") <> " [data-preview-link]")

      assert view |> element(item("ready") <> " [data-preview-fact=\"commit\"]") |> render() =~
               PreviewFixtures.later_commit()
    end

    test "every state is named in words beside an icon, never colour alone", %{
      conn: conn,
      project: project,
      feature: feature,
      account: account,
      authority: authority
    } do
      for state <- [:pending, :ready, :failed, :timed_out, :expired] do
        PreviewFixtures.preview_fixture(authority, project, feature, state)
      end

      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(feature_path(project, feature))

      for {state, label} <- [
            {"pending", "Deploying"},
            {"ready", "Ready"},
            {"failed", "Failed"},
            {"timed_out", "Timed out"},
            {"expired", "Expired"}
          ] do
        badge = view |> element(item(state) <> " [data-preview-state-label]") |> render()

        assert badge =~ label
        assert badge =~ "<svg"
      end

      # Every deployment is labelled non-production, whatever became of it.
      assert view |> render() |> count("data-preview-nonproduction") == 5
    end

    test "the section labels itself for a screen reader and discloses no address", %{
      conn: conn,
      context: context,
      project: project,
      feature: feature,
      account: account,
      authority: authority
    } do
      PreviewFixtures.preview_fixture(authority, project, feature, :ready)

      {:ok, view, html} =
        conn |> log_in_account(account) |> live(feature_path(project, feature))

      section = view |> element("[data-preview]") |> render()

      assert section =~ "aria-labelledby=\"preview-heading\""
      assert section =~ "id=\"preview-heading\""

      refute html =~ "vault://"
      refute html =~ "@example.com"
      refute html =~ context.identity.hosted_identity.id
    end

    test "the preview independence statement is on the screen, not only in the code", %{
      conn: conn,
      project: project,
      feature: feature,
      account: account
    } do
      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(feature_path(project, feature))

      independence = view |> element("[data-preview-independence]") |> render()

      assert independence =~ "non-production"
      assert independence =~ "ready for review"
    end

    for state <- [:none, :pending, :failed, :timed_out, :expired] do
      test "a verified feature reaches review with a #{state} preview [AC-22]", %{
        conn: conn,
        project: project,
        feature: feature,
        account: account,
        authority: authority
      } do
        reviewed(authority, project, feature, unquote(state))

        {:ok, view, _html} =
          conn |> log_in_account(account) |> live(feature_path(project, feature))

        assert view |> element("[data-feature-column]") |> render() =~ "Ready for review"
        assert has_element?(view, "[data-review-handoff]")
        refute has_element?(view, "[data-preview-link]")
      end
    end

    test "a verified feature with no preview path at all still reaches review [AC-22]", %{
      conn: conn,
      project: project,
      feature: feature,
      account: account,
      authority: authority
    } do
      reviewed(authority, project, feature, :none)
      on_exit(PreviewFixtures.unconfigure())

      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(feature_path(project, feature))

      assert has_element?(view, "[data-review-handoff]")
      assert has_element?(view, "[data-preview-unavailable]")
      refute has_element?(view, "[data-preview-link]")
    end
  end

  defp item(state), do: "[data-preview-item][data-preview-state=\"#{state}\"]"

  # One verified run, with or without a preview, handed over to human review.
  defp reviewed(authority, project, feature, :none) do
    context = PreviewFixtures.run_fixture(authority, project, feature)

    DeliveryFixtures.verified_completion_fixture(
      authority,
      project,
      context.run,
      context.attempt
    )

    hand_over(authority, project, context)
  end

  defp reviewed(authority, project, feature, state) do
    authority
    |> PreviewFixtures.preview_fixture(project, feature, state)
    |> then(&hand_over(authority, project, &1))
  end

  defp hand_over(authority, project, context) do
    {:ok, %{applied?: true}} = ReviewHandoff.deliver(authority, project.id, context.run)
    context
  end

  describe "project navigation (AC-48)" do
    test "marks Features as current without claiming to be that page", %{
      conn: conn,
      project: project,
      feature: feature,
      account: account
    } do
      {:ok, view, html} =
        conn |> log_in_account(account) |> live(feature_path(project, feature))

      assert has_element?(view, "nav[aria-label='Project'][data-project-nav]")

      # One feature lives under the board, so the board is current but this is
      # not that exact page.
      assert has_element?(view, ~s([data-nav-destination="features"][data-nav-current]))
      assert has_element?(view, ~s([data-nav-destination="features"][aria-current="true"]))
      refute has_element?(view, ~s([data-nav-destination="features"][aria-current="page"]))

      # The `Features` back button the navigation replaced is gone: the board is
      # linked exactly once, from the navigation row.
      assert count(html, ~s(href="/projects/#{project.id}/features")) == 1
    end

    test "builds every destination from this project only", %{
      conn: conn,
      project: project,
      feature: feature,
      account: account
    } do
      %{project: other_project} = DeliveryFixtures.delivery_project_fixture()

      {:ok, view, html} =
        conn |> log_in_account(account) |> live(feature_path(project, feature))

      refute html =~ other_project.id

      hrefs =
        view
        |> element("[data-project-nav]")
        |> render()
        |> then(&Regex.scan(~r/href="([^"]+)"/, &1, capture: :all_but_first))
        |> List.flatten()

      assert length(hrefs) == 3
      assert Enum.all?(hrefs, &String.starts_with?(&1, "/projects/#{project.id}/"))
    end

    test "hides the owner-only overview from a participant", %{
      conn: conn,
      project: project,
      feature: feature,
      context: context
    } do
      {:ok, view, _html} =
        conn
        |> log_in_hosted(context.identity.hosted_identity)
        |> live(feature_path(project, feature))

      refute has_element?(view, ~s([data-nav-destination="overview"]))
      assert has_element?(view, ~s([data-nav-destination="features"][data-nav-current]))
      assert has_element?(view, ~s([data-nav-destination="people"]))
    end
  end

  defp count(html, needle), do: html |> String.split(needle) |> length() |> Kernel.-(1)

  # One run whose contracted checks all passed for the commit under review, so
  # the screen is proved against a completion the gate genuinely recorded.
  defp proven_run(authority, project, feature) do
    unique = System.unique_integer([:positive])
    digest = DeliveryFixtures.digest("rev-#{unique}")

    {:ok, %{run: run, attempt: attempt}} =
      DeliveryStore.commit(authority, project.id, [
        {:run,
         {:insert_run,
          %{
            project_id: project.id,
            feature_id: feature.id,
            starting_revision_id: "rev-#{unique}",
            starting_revision_digest: digest,
            approved_slice: "slice-07",
            branch: "sdd/feature-#{unique}"
          }}},
        {:attempt,
         {:insert_attempt,
          %{
            run_id: {:ref, :run, :id},
            attempt_number: 1,
            continuation_reason: "initial",
            effective_revision_id: "rev-#{unique}",
            effective_revision_digest: digest,
            manifest_digest: DeliveryFixtures.digest("manifest-#{unique}"),
            required_checks: DeliveryFixtures.required_check_contract(["mix test"]),
            fence_token: 1
          }}}
      ])

    DeliveryFixtures.verified_completion_fixture(authority, project, run, attempt)

    %{run: run, attempt: attempt}
  end

  # One more feature that reached `Ready for review` the only way a decision
  # accepts, for a test that needs two decisions and may only make one per
  # feature.
  defp awaiting_review(context, project, account) do
    feature = project |> DeliveryFixtures.feature_fixture(account) |> in_development()
    run = proven_run(context.workspace, project, feature)

    {:ok, %{applied?: true}} = ReviewHandoff.deliver(context.workspace, project.id, run.run)

    Repo.get!(Feature, feature.id)
  end

  # The execution boundary a continuation's manifest is built from. It is the
  # same one the start and retry paths are proved against, because a rejection
  # binds its next attempt to the configured branch, worker, and agent rather
  # than to anything the reviewer wrote.
  defp configure_execution do
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
  end

  # A declared contradiction locates the run's own workspace before it opens a
  # question about it, and containment is decided against the root's real
  # location, so this has to be a directory that exists rather than a plausible
  # string.
  defp configure_workspace_root do
    root =
      Path.join(System.tmp_dir!(), "review-continuation-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    previous = Application.fetch_env(:sdd_orchestrator, :worker_workspace_root)
    Application.put_env(:sdd_orchestrator, :worker_workspace_root, root)

    on_exit(fn ->
      File.rm_rf(root)

      case previous do
        {:ok, value} -> Application.put_env(:sdd_orchestrator, :worker_workspace_root, value)
        :error -> Application.delete_env(:sdd_orchestrator, :worker_workspace_root)
      end
    end)

    root
  end

  defp fact(view, scope, name) do
    view |> element("#{scope} [data-evidence-fact=\"#{name}\"]") |> render()
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
