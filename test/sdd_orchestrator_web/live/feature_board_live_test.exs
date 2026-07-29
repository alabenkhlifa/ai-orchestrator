defmodule SddOrchestratorWeb.FeatureBoardLiveTest do
  use SddOrchestratorWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias SddOrchestrator.Delivery.{Feature, Features}
  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.HostedAccess.SessionCookie
  alias SddOrchestrator.Participation
  alias SddOrchestrator.Participation.Revocations
  alias SddOrchestrator.ParticipationDeliveryDouble
  alias SddOrchestrator.ParticipationFixtures
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

    :ok
  end

  describe "the five lifecycle columns" do
    test "renders every column on an empty board", %{conn: conn} do
      %{project: project, account: account} = DeliveryFixtures.delivery_project_fixture()

      {:ok, view, html} =
        conn |> log_in_account(account) |> live(~p"/projects/#{project.id}/features")

      for column <- Feature.columns() do
        assert has_element?(view, ~s([data-column="#{column}"]))
        assert has_element?(view, ~s([data-column="#{column}"] [data-column-empty]))
      end

      assert html =~ "Draft"
      assert html =~ "Ready for development"
      assert html =~ "In development"
      assert html =~ "Ready for review"
      assert html =~ "Done"
      refute has_element?(view, "[data-feature]")
    end

    test "groups each feature under its own column", %{conn: conn} do
      %{project: project, account: account, owner_actor: actor} =
        DeliveryFixtures.delivery_project_fixture()

      draft = DeliveryFixtures.feature_fixture(project, account, %{title: "Draft feature"})
      moving = DeliveryFixtures.feature_fixture(project, account, %{title: "Ready feature"})
      {:ok, ready} = Features.transition(project.id, actor, moving, "ready_for_development")
      {:ok, running} = Features.transition(project.id, actor, ready, "in_development")
      {:ok, _blocked} = Features.put_status(project.id, actor, running, "blocked")

      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(~p"/projects/#{project.id}/features")

      assert has_element?(view, ~s([data-column="draft"] [data-feature-id="#{draft.id}"]))

      assert has_element?(
               view,
               ~s([data-column="in_development"] [data-feature-id="#{running.id}"])
             )

      refute has_element?(view, ~s([data-column="draft"] [data-feature-id="#{running.id}"]))

      # `Blocked` is a status on the card, not a column of its own.
      refute has_element?(view, ~s([data-column="blocked"]))

      assert view
             |> element(~s([data-feature-id="#{running.id}"] [data-feature-status-label]))
             |> render() =~ "Blocked"
    end
  end

  describe "no free movement" do
    test "the board exposes no drag affordance or column control", %{conn: conn} do
      %{project: project, account: account} = DeliveryFixtures.delivery_project_fixture()
      DeliveryFixtures.feature_fixture(project, account)

      {:ok, view, html} =
        conn |> log_in_account(account) |> live(~p"/projects/#{project.id}/features")

      assert html =~ ~s(data-drag-enabled="false")
      refute html =~ "draggable"
      refute html =~ "phx-hook"

      # A card carries no control that could move it: its only interaction is a
      # link to the feature's own screen, where the gated action lives.
      card = view |> element("[data-feature]") |> render()
      refute card =~ "phx-click"
      refute card =~ "phx-value-to"
      assert card =~ "/features/"
    end

    test "a direct or illegal transition is rejected by the domain" do
      %{project: project, account: account, owner_actor: actor} =
        DeliveryFixtures.delivery_project_fixture()

      feature = DeliveryFixtures.feature_fixture(project, account)

      assert {:error, :illegal_transition} =
               Features.transition(project.id, actor, feature, "done")

      assert {:error, :illegal_transition} =
               Features.transition(project.id, actor, feature, "in_development")

      assert Repo.get!(Feature, feature.id).lifecycle_column == "draft"
    end
  end

  describe "identity presentation" do
    test "labels creators by project display name and never by email", %{conn: conn} do
      %{project: project, account: account, identity: identity} =
        DeliveryFixtures.delivery_project_fixture()

      owner_label = Participation.owner_profile(project.id).display_name
      member_label = Participation.member_profile(project.id, identity.account.id).display_name

      DeliveryFixtures.feature_fixture(project, account, %{title: "Owner's feature"})

      DeliveryFixtures.feature_fixture(project, identity.account, %{
        title: "Member's feature",
        assigned_account_id: identity.account.id
      })

      {:ok, view, html} =
        conn |> log_in_account(account) |> live(~p"/projects/#{project.id}/features")

      assert html =~ owner_label
      assert html =~ member_label
      refute html =~ identity.external_identity.display_identifier
      assert has_element?(view, "[data-feature-assignee]")
    end

    test "shows a departed creator without exposing their identity", %{conn: conn} do
      %{project: project, account: account, identity: identity} =
        DeliveryFixtures.delivery_project_fixture()

      DeliveryFixtures.feature_fixture(project, identity.account, %{title: "Legacy feature"})
      {:ok, _removed} = Revocations.remove(project, account.id, identity.hosted_identity.id)

      {:ok, view, html} =
        conn |> log_in_account(account) |> live(~p"/projects/#{project.id}/features")

      assert html =~ "Legacy feature"
      assert view |> element("[data-feature-creator]") |> render() =~ "A former member"
      refute html =~ identity.external_identity.display_identifier
    end
  end

  describe "authorization" do
    test "a participant sees the board and an outsider does not", %{conn: conn} do
      %{project: project, identity: identity} = DeliveryFixtures.delivery_project_fixture()
      outsider = ParticipationFixtures.invited_identity_fixture()

      access =
        SddOrchestrator.HostedAccessFixtures.verified_hosted_session_fixture(%{
          email: identity.external_identity.display_identifier
        })

      {:ok, _view, html} =
        conn |> hosted(access) |> live(~p"/projects/#{project.id}/features")

      assert html =~ "data-screen=\"feature-board\""

      outsider_access =
        SddOrchestrator.HostedAccessFixtures.verified_hosted_session_fixture(%{
          email: outsider.external_identity.display_identifier
        })

      assert {:error, {:live_redirect, %{to: "/projects"}}} =
               build_conn()
               |> hosted(outsider_access)
               |> live(~p"/projects/#{project.id}/features")

      assert {:error, {:live_redirect, %{to: "/projects"}}} =
               build_conn() |> live(~p"/projects/#{project.id}/features")
    end

    test "a feature from another project is not reachable", %{conn: conn} do
      %{project: project, account: account} = DeliveryFixtures.delivery_project_fixture()

      %{project: other_project, account: other_account} =
        DeliveryFixtures.delivery_project_fixture()

      feature = DeliveryFixtures.feature_fixture(project, account)

      assert {:error, {:live_redirect, %{to: path}}} =
               conn
               |> log_in_account(other_account)
               |> live(~p"/projects/#{other_project.id}/features/#{feature.id}")

      assert path == "/projects/#{other_project.id}/features"
    end
  end

  describe "creating and opening a feature" do
    test "adds a feature to Draft and opens its detail screen", %{conn: conn} do
      %{project: project, account: account} = DeliveryFixtures.delivery_project_fixture()

      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(~p"/projects/#{project.id}/features")

      html =
        view
        |> form("#new-feature-form", feature: %{title: "  Search filters  "})
        |> render_submit()

      assert html =~ "Search filters"
      created = Repo.one!(Feature)
      assert created.title == "Search filters"
      assert created.lifecycle_column == "draft"
      assert has_element?(view, ~s([data-column="draft"] [data-feature-id="#{created.id}"]))

      {:ok, _detail, detail_html} =
        conn
        |> log_in_account(account)
        |> live(~p"/projects/#{project.id}/features/#{created.id}")

      assert detail_html =~ "Search filters"
      assert detail_html =~ "Draft"
      assert detail_html =~ "data-gated-action"
      refute detail_html =~ "data-feature-status"
    end

    test "rejects a blank title without adding a card", %{conn: conn} do
      %{project: project, account: account} = DeliveryFixtures.delivery_project_fixture()

      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(~p"/projects/#{project.id}/features")

      view |> form("#new-feature-form", feature: %{title: "   "}) |> render_submit()

      assert Repo.aggregate(Feature, :count) == 0
      refute has_element?(view, "[data-feature]")
    end
  end

  describe "responsive and accessible structure" do
    test "stacks columns on small screens and labels the controls", %{conn: conn} do
      %{project: project, account: account} = DeliveryFixtures.delivery_project_fixture()
      DeliveryFixtures.feature_fixture(project, account)

      {:ok, _view, html} =
        conn |> log_in_account(account) |> live(~p"/projects/#{project.id}/features")

      assert html =~ "grid-cols-1 gap-4 sm:grid-cols-2 xl:grid-cols-5"
      assert html =~ "w-full sm:w-auto"
      assert html =~ ~s(<label for="feature-title")
      assert html =~ "focus:outline focus:outline-2 focus:outline-focus"
    end
  end

  defp hosted(conn, access) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(SessionCookie.session_key(), access.session_cookie.value)
  end
end
