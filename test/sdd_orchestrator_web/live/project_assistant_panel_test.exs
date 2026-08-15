defmodule SddOrchestratorWeb.ProjectAssistantPanelTest.SlowModelCompletionAdapter do
  @moduledoc """
  A `ModelCompletionAdapter` test double that sleeps before delegating to
  `FakeModelCompletionAdapter`, so a cancel test can deterministically
  interact with the panel while its async ask task is still in flight
  instead of racing a near-instant completion.
  """
  @behaviour SddOrchestrator.ProjectAssistant.ModelCompletionAdapter

  alias SddOrchestrator.ProjectAssistant.FakeModelCompletionAdapter

  @impl true
  def complete(request) do
    Process.sleep(1_000)
    FakeModelCompletionAdapter.complete(request)
  end
end

defmodule SddOrchestratorWeb.ProjectAssistantPanelTest do
  use SddOrchestratorWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias SddOrchestrator.AIRuntimeFixtures
  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.HostedAccess.SessionCookie
  alias SddOrchestrator.HostedAccessFixtures
  alias SddOrchestrator.ProjectAssistant.{BoundaryGate, FakeModelCompletionAdapter}
  alias SddOrchestrator.ProjectAssistant.TurnOrchestrator
  alias SddOrchestrator.SpecificationFixtures
  alias SddOrchestratorWeb.ProjectAssistantPanelTest.SlowModelCompletionAdapter

  setup do
    previous = Application.get_env(:sdd_orchestrator, :model_completion_adapter)
    Application.put_env(:sdd_orchestrator, :model_completion_adapter, FakeModelCompletionAdapter)

    on_exit(fn ->
      if previous do
        Application.put_env(:sdd_orchestrator, :model_completion_adapter, previous)
      else
        Application.delete_env(:sdd_orchestrator, :model_completion_adapter)
      end
    end)

    :ok
  end

  defp hosted(conn, access) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(SessionCookie.session_key(), access.session_cookie.value)
  end

  # Links a personal AI connection, a current model catalog, and a current
  # quota snapshot for `account` through the real public boundaries each own
  # module already proves, then confirms the disclosed processing boundary
  # so `askable?/1`'s two conditions (`state: :available`,
  # `confirmation_required: false`) both hold without exercising the
  # confirmation UI itself (a separate test below owns that).
  defp make_available_and_confirmed(workspace, project, actor, account) do
    now = DateTime.utc_now()
    AIRuntimeFixtures.runtime_session_context_fixture(%{account: account, now: now})
    {:ok, _confirmation} = BoundaryGate.confirm(workspace, project.id, actor, account, now: now)
    :ok
  end

  describe "reachability and navigation preservation" do
    test "the panel mounts on the feature board, opens, and preserves the current screen", %{
      conn: conn
    } do
      %{project: project, account: account} = DeliveryFixtures.delivery_project_fixture()

      {:ok, view, html} =
        conn |> log_in_account(account) |> live(~p"/projects/#{project.id}/features")

      assert html =~ ~s(data-screen="feature-board")
      assert has_element?(view, "[data-project-assistant]")
      refute has_element?(view, "[data-project-assistant-panel]")

      view |> element("[data-project-assistant-toggle]") |> render_click()

      assert has_element?(view, "[data-project-assistant-panel]")
      # Opening the panel is an in-page state change, not a navigation: the
      # underlying screen is still mounted and rendered, never replaced.
      assert has_element?(view, ~s([data-screen="feature-board"]))
    end

    test "the panel mounts on the project overview, participation, and assessment screens", %{
      conn: conn
    } do
      %{project: project, account: account} = DeliveryFixtures.delivery_project_fixture()

      for path <- [
            ~p"/projects/#{project.id}/overview",
            ~p"/projects/#{project.id}/participation"
          ] do
        {:ok, view, _html} = conn |> log_in_account(account) |> live(path)
        assert has_element?(view, "[data-project-assistant]")
      end
    end
  end

  describe "private history" do
    test "each participant sees only their own conversation", %{conn: conn} do
      %{project: project, workspace: workspace, account: account, identity: identity} =
        DeliveryFixtures.delivery_project_fixture()

      SpecificationFixtures.hosted_specification(workspace, project)
      owner_actor = %{account_id: account.id, hosted_identity_id: nil}
      :ok = make_available_and_confirmed(workspace, project, owner_actor, account)

      {:ok, {_conversation, _turn, _citations}} =
        TurnOrchestrator.answer(workspace, project.id, owner_actor, account, "spec-valid: hi")

      {:ok, owner_view, _html} =
        conn |> log_in_account(account) |> live(~p"/projects/#{project.id}/features")

      owner_view |> element("[data-project-assistant-toggle]") |> render_click()

      assert owner_view |> element("[data-project-assistant-history]") |> render() =~
               "spec-valid: hi"

      access =
        HostedAccessFixtures.verified_hosted_session_fixture(%{
          email: identity.external_identity.display_identifier
        })

      {:ok, participant_view, _html} =
        build_conn() |> hosted(access) |> live(~p"/projects/#{project.id}/features")

      participant_view |> element("[data-project-assistant-toggle]") |> render_click()
      history = participant_view |> element("[data-project-assistant-history]") |> render()
      refute history =~ "spec-valid: hi"
    end

    test "a removed participant's panel fails closed without exposing history", %{conn: conn} do
      %{project: project, workspace: _workspace, account: account, identity: identity} =
        DeliveryFixtures.delivery_project_fixture()

      access =
        HostedAccessFixtures.verified_hosted_session_fixture(%{
          email: identity.external_identity.display_identifier
        })

      {:ok, view, _html} = conn |> hosted(access) |> live(~p"/projects/#{project.id}/features")

      SddOrchestrator.Participation.Revocations.remove(
        project,
        account.id,
        identity.hosted_identity.id
      )

      view |> element("[data-project-assistant-toggle]") |> render_click()
      refute has_element?(view, "[data-project-assistant-panel]")
    end
  end

  describe "degraded states" do
    test "no personal AI connection shows the safe setup-needed state", %{conn: conn} do
      %{project: project, account: account} = DeliveryFixtures.delivery_project_fixture()

      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(~p"/projects/#{project.id}/features")

      view |> element("[data-project-assistant-toggle]") |> render_click()

      assert has_element?(
               view,
               ~s([data-project-assistant-availability][data-availability-state="setup_needed"])
             )

      assert view |> element("[data-project-assistant-question]") |> render() =~ "disabled"
    end

    test "the setup-needed state never discloses another person's usage, credentials, or exact quota",
         %{conn: conn} do
      %{project: project, account: account} = DeliveryFixtures.delivery_project_fixture()

      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(~p"/projects/#{project.id}/features")

      view |> element("[data-project-assistant-toggle]") |> render_click()
      html = view |> element("[data-project-assistant-panel]") |> render()

      for forbidden <- ["quota", "credit", "credential", "api_key", "token", "@"] do
        refute String.contains?(String.downcase(html), forbidden),
               "assistant panel unexpectedly rendered #{inspect(forbidden)}"
      end
    end
  end

  describe "boundary confirmation" do
    test "the first question requires disclosure confirmation, then proceeds", %{conn: conn} do
      %{project: project, account: account} = DeliveryFixtures.delivery_project_fixture()

      AIRuntimeFixtures.runtime_session_context_fixture(%{
        account: account,
        now: DateTime.utc_now()
      })

      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(~p"/projects/#{project.id}/features")

      view |> element("[data-project-assistant-toggle]") |> render_click()

      assert has_element?(view, "[data-project-assistant-disclosure]")
      assert view |> element("[data-project-assistant-ask]") |> render() =~ "disabled"

      view |> element("[data-project-assistant-confirm-boundary]") |> render_click()

      refute has_element?(view, "[data-project-assistant-disclosure]")

      view
      |> form("[data-project-assistant-panel] form",
        question: %{text: "spec-valid: after confirming"}
      )
      |> render_submit()

      assert render_async(view, 2_000) =~ "spec-valid: after confirming"
    end
  end

  describe "ask, citations, and uncertainty" do
    setup %{conn: conn} do
      %{project: project, workspace: workspace, account: account} =
        DeliveryFixtures.delivery_project_fixture()

      owner_actor = %{account_id: account.id, hosted_identity_id: nil}
      SpecificationFixtures.hosted_specification(workspace, project)
      :ok = make_available_and_confirmed(workspace, project, owner_actor, account)

      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(~p"/projects/#{project.id}/features")

      view |> element("[data-project-assistant-toggle]") |> render_click()

      %{view: view, project: project}
    end

    test "a resolved specification citation is readable after opening it", %{view: view} do
      view
      |> form("[data-project-assistant-panel] form",
        question: %{text: "spec-valid: what is current"}
      )
      |> render_submit()

      assert render_async(view, 2_000) =~ "The current specification is"

      assert has_element?(
               view,
               "[data-project-assistant-citation][data-citation-source-type=specification]"
             )

      view
      |> element("[data-project-assistant-citation][data-citation-source-type=specification]")
      |> render_click()

      assert has_element?(view, "[data-project-assistant-citation-detail]")
      assert render(view) =~ "Specification storage"
    end

    test "a repository claim resolves as a visible source-unavailable marker, not a citation", %{
      view: view
    } do
      view
      |> form("[data-project-assistant-panel] form",
        question: %{text: "repository-valid: source please"}
      )
      |> render_submit()

      html = render_async(view, 2_000)
      assert has_element?(view, ~s([data-marker-type="unavailable"]))
      refute has_element?(view, "[data-citation-source-type=repository]")
      assert html =~ "Source unavailable"
    end

    test "a failed turn shows safe copy and a retry affordance that refills the question", %{
      view: view
    } do
      view
      |> form("[data-project-assistant-panel] form",
        question: %{text: "fails: model_unavailable"}
      )
      |> render_submit()

      html = render_async(view, 2_000)
      assert has_element?(view, "[data-turn-failure]")
      assert html =~ "reach your personal AI connection"

      view |> element("[data-project-assistant-retry]") |> render_click()

      assert view |> element("[data-project-assistant-question]") |> render() =~
               "fails: model_unavailable"
    end

    test "cancel clears a pending question", %{view: view} do
      previous = Application.get_env(:sdd_orchestrator, :model_completion_adapter)

      Application.put_env(
        :sdd_orchestrator,
        :model_completion_adapter,
        SlowModelCompletionAdapter
      )

      view
      |> form("[data-project-assistant-panel] form", question: %{text: "spec-valid: pending"})
      |> render_submit()

      assert has_element?(view, "[data-project-assistant-pending]")
      assert render(view) =~ "spec-valid: pending"

      view |> element("[data-project-assistant-cancel-ask]") |> render_click()

      refute has_element?(view, "[data-project-assistant-pending]")
      refute render(view) =~ "spec-valid: pending"

      Application.put_env(
        :sdd_orchestrator,
        :model_completion_adapter,
        previous || FakeModelCompletionAdapter
      )
    end
  end

  describe "delete" do
    test "delete removes the conversation immediately", %{conn: conn} do
      %{project: project, workspace: workspace, account: account} =
        DeliveryFixtures.delivery_project_fixture()

      SpecificationFixtures.hosted_specification(workspace, project)
      owner_actor = %{account_id: account.id, hosted_identity_id: nil}
      :ok = make_available_and_confirmed(workspace, project, owner_actor, account)

      {:ok, {_conversation, _turn, _citations}} =
        TurnOrchestrator.answer(workspace, project.id, owner_actor, account, "spec-valid: hi")

      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(~p"/projects/#{project.id}/features")

      view |> element("[data-project-assistant-toggle]") |> render_click()
      assert render(view) =~ "spec-valid: hi"

      view |> element("[data-project-assistant-delete]") |> render_click()
      view |> element("[data-project-assistant-delete-confirm-yes]") |> render_click()

      refute render(view) =~ "spec-valid: hi"
      refute has_element?(view, "[data-project-assistant-delete]")
    end
  end

  describe "no mutation controls" do
    test "the panel exposes no comment, assignment, or run control", %{conn: conn} do
      %{project: project, account: account} = DeliveryFixtures.delivery_project_fixture()

      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(~p"/projects/#{project.id}/features")

      view |> element("[data-project-assistant-toggle]") |> render_click()
      html = view |> element("[data-project-assistant-panel]") |> render()

      for forbidden <- [
            "data-assign",
            "data-comment",
            "data-start-run",
            "data-retry-run",
            "data-approve",
            "data-reject"
          ] do
        refute html =~ forbidden
      end
    end
  end
end
