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

  alias SddOrchestrator.Delivery.{Assignment, Feature}
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

  defp feature_path(project, feature), do: ~p"/projects/#{project.id}/features/#{feature.id}"

  defp log_in_hosted(conn, hosted_identity) do
    {:ok, _session, cookie} = Sessions.create(hosted_identity, %{})

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(SessionCookie.session_key(), cookie.value)
  end
end
