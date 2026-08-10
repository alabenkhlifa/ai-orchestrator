defmodule SddOrchestratorWeb.FeatureSpecificationLinkLiveTest do
  @moduledoc """
  Screen proof for the owner-facing specification-link control (Task 2 of
  specs/35-guided-delivery-feature-specification-link).

  The control has to make two things true at once: the owner can actually
  link, change, or clear a feature's specification from this screen, and
  nobody else can reach the same action, whether through the missing control
  or a direct event.
  """
  use SddOrchestratorWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias SddOrchestrator.Delivery.Feature
  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.HostedAccess.SessionCookie
  alias SddOrchestrator.HostedAccess.Sessions
  alias SddOrchestrator.Repo
  alias SddOrchestrator.SpecificationFixtures

  setup do
    context = DeliveryFixtures.delivery_project_fixture()
    feature = DeliveryFixtures.feature_fixture(context.project, context.account)

    %{
      context: context,
      project: context.project,
      workspace: context.workspace,
      feature: feature,
      account: context.account
    }
  end

  defp specification(workspace, project, overrides \\ %{}) do
    SpecificationFixtures.hosted_specification(workspace, project, overrides)
  end

  describe "presentation [AC-01]" do
    test "the owner sees the control with the unlinked state and every current specification",
         %{conn: conn, project: project, workspace: workspace, feature: feature, account: account} do
      first = specification(workspace, project, %{title: "First specification"})
      second = specification(workspace, project, %{title: "Second specification"})

      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(feature_path(project, feature))

      select = view |> element("[data-specification-link-select]") |> render()

      assert select =~ "Not linked"
      assert select =~ first.specification.title
      assert select =~ second.specification.title

      assert view |> element("[data-specification-link-select] option[selected]") |> render() =~
               "Not linked"
    end

    test "a specification already linked to another feature is not offered [AC-01]", %{
      conn: conn,
      context: context,
      project: project,
      workspace: workspace,
      feature: feature,
      account: account
    } do
      other_feature = DeliveryFixtures.feature_fixture(project, account)
      taken = specification(workspace, project, %{title: "Already linked elsewhere"})
      available = specification(workspace, project, %{title: "Still available"})

      {:ok, _linked} =
        SddOrchestrator.Delivery.Features.link_specification(
          workspace,
          project.id,
          context.owner_actor,
          other_feature,
          taken.specification.id
        )

      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(feature_path(project, feature))

      select = view |> element("[data-specification-link-select]") |> render()

      refute select =~ taken.specification.title
      assert select =~ available.specification.title
    end

    test "a non-owner participant does not see the specification-link section at all [AC-05]",
         %{conn: conn, context: context, project: project, workspace: workspace, feature: feature} do
      specification(workspace, project)

      {:ok, _view, html} =
        conn
        |> log_in_hosted(context.identity.hosted_identity)
        |> live(feature_path(project, feature))

      refute html =~ "data-specification-link"
    end
  end

  describe "linking" do
    test "the owner links the feature to a current specification", %{
      conn: conn,
      project: project,
      workspace: workspace,
      feature: feature,
      account: account
    } do
      current = specification(workspace, project, %{title: "Target specification"})

      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(feature_path(project, feature))

      view
      |> form("#specification-link-form", %{
        "specification" => %{"specification_id" => current.specification.id}
      })
      |> render_change()

      assert Repo.get!(Feature, feature.id).specification_id == current.specification.id

      assert {:ok, resolved} =
               SddOrchestrator.Delivery.Features.fetch_by_specification(
                 project.id,
                 current.specification.id
               )

      assert resolved.id == feature.id

      assert view |> element("[data-specification-link-select] option[selected]") |> render() =~
               current.specification.title
    end

    test "the owner clears an existing link", %{
      conn: conn,
      context: context,
      project: project,
      workspace: workspace,
      feature: feature,
      account: account
    } do
      current = specification(workspace, project)

      {:ok, linked} =
        SddOrchestrator.Delivery.Features.link_specification(
          workspace,
          project.id,
          context.owner_actor,
          feature,
          current.specification.id
        )

      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(feature_path(project, linked))

      view
      |> form("#specification-link-form", %{"specification" => %{"specification_id" => ""}})
      |> render_change()

      refute Repo.get!(Feature, feature.id).specification_id

      assert view |> element("[data-specification-link-select] option[selected]") |> render() =~
               "Not linked"
    end
  end

  describe "authorization [AC-05]" do
    test "a non-owner participant who sends the event directly is refused, and the feature is unchanged",
         %{conn: conn, context: context, project: project, workspace: workspace, feature: feature} do
      current = specification(workspace, project)
      before = Repo.get!(Feature, feature.id)

      {:ok, view, _html} =
        conn
        |> log_in_hosted(context.identity.hosted_identity)
        |> live(feature_path(project, feature))

      render_change(view, "link_specification", %{
        "specification" => %{"specification_id" => current.specification.id}
      })

      assert_redirect(view, ~p"/projects")

      assert Repo.get!(Feature, feature.id) == before
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
