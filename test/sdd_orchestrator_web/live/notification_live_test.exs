defmodule SddOrchestratorWeb.NotificationLiveTest do
  @moduledoc """
  Proof for the accessible notification inbox (specs/17 Task 4, AC-04).

  Covers listing an authorized current participant's own delivery
  notifications, the empty state, marking read (idempotently), opening a
  notification's safe link, non-disclosing refusal of a notification that
  went stale between render and action, the responsive/accessible structure
  the desktop and mobile layouts share, and the `/notifications` entry point
  offered from `ProjectsLive`.
  """
  use SddOrchestratorWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias SddOrchestrator.AccountsFixtures
  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.HostedAccess.SessionCookie
  alias SddOrchestrator.HostedAccessFixtures
  alias SddOrchestrator.Notifications
  alias SddOrchestrator.Notifications.AccountNotification
  alias SddOrchestrator.Participation.Revocations
  alias SddOrchestrator.ProjectsFixtures
  alias SddOrchestrator.Repo

  describe "listing (AC-04)" do
    test "an authorized owner sees their own notifications listed", %{conn: conn} do
      %{project: project, account: account} = DeliveryFixtures.delivery_project_fixture()
      feature = DeliveryFixtures.feature_fixture(project, account)

      {:ok, notification} =
        Notifications.deliver(notification_attrs(account, project, feature))

      {:ok, view, html} = conn |> log_in_account(account) |> live(~p"/notifications")

      assert html =~ project.name
      assert html =~ notification.title
      assert html =~ notification.body
      assert html =~ "UTC"
      assert has_element?(view, "#notification-#{notification.id}-mark-read", "Mark read")
      refute view |> element("#notification-#{notification.id}") |> render() =~ "Read"
    end

    test "an authorized hosted-identity-linked participant sees their own notifications listed",
         %{conn: conn} do
      %{project: project, identity: identity} = DeliveryFixtures.delivery_project_fixture()
      feature = DeliveryFixtures.feature_fixture(project, identity.account)

      {:ok, notification} =
        Notifications.deliver(notification_attrs(identity.account, project, feature))

      access =
        HostedAccessFixtures.verified_hosted_session_fixture(
          email: identity.external_identity.display_identifier
        )

      {:ok, _view, html} =
        conn |> log_in_account(identity.account) |> hosted(access) |> live(~p"/notifications")

      assert html =~ notification.title
      assert html =~ notification.body
    end
  end

  describe "empty state (AC-04)" do
    test "renders the caught-up empty state when there are no notifications", %{conn: conn} do
      %{account: account} = DeliveryFixtures.delivery_project_fixture()

      {:ok, view, html} = conn |> log_in_account(account) |> live(~p"/notifications")

      assert html =~ "You&#39;re all caught up"
      refute has_element?(view, "[data-notification]")
    end
  end

  describe "marking read (AC-04)" do
    test "flips an unread notification to a Read badge and stays idempotent on a second click",
         %{conn: conn} do
      %{project: project, account: account} = DeliveryFixtures.delivery_project_fixture()
      feature = DeliveryFixtures.feature_fixture(project, account)

      {:ok, notification} =
        Notifications.deliver(notification_attrs(account, project, feature))

      {:ok, view, _html} = conn |> log_in_account(account) |> live(~p"/notifications")

      html =
        view
        |> element("#notification-#{notification.id}-mark-read", "Mark read")
        |> render_click()

      assert html =~ "Read"
      refute has_element?(view, "#notification-#{notification.id}-mark-read")

      first_read_at = Repo.get!(AccountNotification, notification.id).read_at
      assert first_read_at

      # The button is gone once read, so idempotency is proven the same way the
      # domain layer proves it: the same event, dispatched again.
      html = render_click(view, "mark_read", %{"id" => notification.id})

      assert html =~ "Read"
      refute html =~ "no longer available"
      assert Repo.get!(AccountNotification, notification.id).read_at == first_read_at
    end
  end

  describe "opening a notification (AC-04)" do
    test "resolves the safe link and navigates there", %{conn: conn} do
      %{project: project, account: account} = DeliveryFixtures.delivery_project_fixture()
      feature = DeliveryFixtures.feature_fixture(project, account)

      {:ok, notification} =
        Notifications.deliver(notification_attrs(account, project, feature))

      {:ok, view, _html} = conn |> log_in_account(account) |> live(~p"/notifications")

      view
      |> element("#notification-#{notification.id}-open", "Open")
      |> render_click()

      assert_redirect(view, notification.link_path)
    end
  end

  describe "stale notifications (AC-04)" do
    test "marking read a notification revoked after render shows a non-disclosing flash and it disappears",
         %{conn: conn} do
      %{project: project, account: owner_account, identity: identity} =
        DeliveryFixtures.delivery_project_fixture()

      feature = DeliveryFixtures.feature_fixture(project, identity.account)

      {:ok, notification} =
        Notifications.deliver(notification_attrs(identity.account, project, feature))

      access =
        HostedAccessFixtures.verified_hosted_session_fixture(
          email: identity.external_identity.display_identifier
        )

      {:ok, view, _html} =
        conn |> log_in_account(identity.account) |> hosted(access) |> live(~p"/notifications")

      assert has_element?(view, "#notification-#{notification.id}")

      {:ok, _removed} =
        Revocations.remove(project, owner_account.id, identity.hosted_identity.id)

      html =
        view
        |> element("#notification-#{notification.id}-mark-read", "Mark read")
        |> render_click()

      assert html =~ "no longer available"
      refute has_element?(view, "#notification-#{notification.id}")
    end

    test "opening a notification revoked after render shows the same flash and it disappears",
         %{conn: conn} do
      %{project: project, account: owner_account, identity: identity} =
        DeliveryFixtures.delivery_project_fixture()

      feature = DeliveryFixtures.feature_fixture(project, identity.account)

      {:ok, notification} =
        Notifications.deliver(notification_attrs(identity.account, project, feature))

      access =
        HostedAccessFixtures.verified_hosted_session_fixture(
          email: identity.external_identity.display_identifier
        )

      {:ok, view, _html} =
        conn |> log_in_account(identity.account) |> hosted(access) |> live(~p"/notifications")

      assert has_element?(view, "#notification-#{notification.id}")

      {:ok, _removed} =
        Revocations.remove(project, owner_account.id, identity.hosted_identity.id)

      html =
        view
        |> element("#notification-#{notification.id}-open", "Open")
        |> render_click()

      assert html =~ "no longer available"
      refute has_element?(view, "#notification-#{notification.id}")
    end
  end

  describe "responsive and accessible structure (AC-04)" do
    test "stacks rows on small screens, exposes a visible focus ring, and keeps stable ids", %{
      conn: conn
    } do
      %{project: project, account: account} = DeliveryFixtures.delivery_project_fixture()
      feature = DeliveryFixtures.feature_fixture(project, account)

      {:ok, notification} =
        Notifications.deliver(notification_attrs(account, project, feature))

      {:ok, _view, html} = conn |> log_in_account(account) |> live(~p"/notifications")

      assert html =~ "sm:flex-row"

      assert html =~
               "focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"

      assert html =~ ~s(id="notification-#{notification.id}")
      assert html =~ ~s(id="notification-#{notification.id}-open")
      assert html =~ ~s(id="notification-#{notification.id}-mark-read")
    end
  end

  describe "entry point (AC-04)" do
    test "is offered from ProjectsLive's actions and is reachable", %{conn: conn} do
      account = AccountsFixtures.account_fixture()
      workspace = ProjectsFixtures.workspace_fixture(account)
      ProjectsFixtures.project_fixture(workspace, name: "Roadmap Alpha")

      {:ok, view, _html} = conn |> log_in_account(account) |> live(~p"/projects")

      assert has_element?(view, ~s([data-notifications-link][href="/notifications"]))

      assert {:ok, _view, _html} =
               conn |> log_in_account(account) |> live(~p"/notifications")
    end
  end

  defp hosted(conn, access) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(SessionCookie.session_key(), access.session_cookie.value)
  end

  defp notification_attrs(account, project, feature, overrides \\ %{}) do
    Map.merge(
      %{
        account_id: account.id,
        event_type: "delivery.run_blocked",
        subject_ref: Ecto.UUID.generate(),
        event_version: 1,
        title: "A run needs an answer",
        body: "A feature is waiting on an answer before development continues.",
        project_label: project.name,
        link_path: "/projects/#{project.id}/features/#{feature.id}",
        occurred_at: DateTime.utc_now() |> DateTime.truncate(:second)
      },
      overrides
    )
  end
end
