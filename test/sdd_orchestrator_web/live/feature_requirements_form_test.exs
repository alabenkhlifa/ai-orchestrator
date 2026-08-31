defmodule SddOrchestratorWeb.FeatureRequirementsFormTest do
  @moduledoc """
  Screen proof for the guided requirements form (Task 2 of
  specs/41-feature-delivery-from-the-ui, AC-02).

  Four things have to hold at once: a save appends exactly one revision holding
  the four parts, the next visit shows them back, a revision written by someone
  else is refused instead of overwritten, and the design and tasks documents the
  coding agent owns are carried forward untouched.
  """
  use SddOrchestratorWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias SddOrchestrator.Delivery.{Features, GuidedRequirements}
  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.HostedAccess.{SessionCookie, Sessions}
  alias SddOrchestrator.Repo
  alias SddOrchestrator.Specifications.SpecificationRevision
  alias SddOrchestrator.SpecificationStore

  @written %{
    "outcome" => "A person can find a feature by typing part of its title.",
    "users" => "Anyone on the project, owner or participant.",
    "rules" => "An empty search shows every feature.",
    "done" => "Typing three letters of a title finds that feature."
  }

  setup %{conn: conn} do
    context = DeliveryFixtures.delivery_project_fixture()

    {:ok, feature} =
      Features.create(context.project.id, context.owner_actor, %{title: "Search features"})

    %{
      conn: conn,
      context: context,
      project: context.project,
      workspace: context.workspace,
      account: context.account,
      feature: feature
    }
  end

  describe "writing the four guided parts" do
    test "the form opens empty, with a labelled field and hint for every part", %{
      conn: conn,
      project: project,
      feature: feature,
      account: account
    } do
      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(feature_path(project, feature))

      for part <- GuidedRequirements.structure() do
        field = view |> element(part_selector(part.key)) |> render()

        assert field =~ "name=\"requirements[#{part.key}]\""

        assert view |> element("[data-requirements-hint=\"#{part.key}\"]") |> render() =~
                 part.hint

        assert view
               |> element("[data-requirements] label[for=\"requirements-#{part.key}\"]")
               |> render() =~ part.label
      end
    end

    test "one save appends exactly one revision holding the four parts [AC-02]", %{
      conn: conn,
      workspace: workspace,
      project: project,
      feature: feature,
      account: account
    } do
      assert [created] = revisions(feature.specification_id)

      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(feature_path(project, feature))

      view
      |> form("#requirements-form", %{"requirements" => @written})
      |> render_submit()

      assert [^created, saved] = revisions(feature.specification_id)
      assert saved.sequence == created.sequence + 1
      assert GuidedRequirements.parse(saved.requirements_document) == @written
      assert saved.actor_ref == account.id

      assert {:ok, current} =
               SpecificationStore.get_current(workspace, project.id, feature.specification_id)

      assert current.revision.id == saved.id
      refute view |> has_element?("[data-requirements-error]")
    end

    test "the next visit shows the saved parts back [AC-02]", %{
      conn: conn,
      project: project,
      feature: feature,
      account: account
    } do
      conn = log_in_account(conn, account)
      {:ok, view, _html} = live(conn, feature_path(project, feature))

      view
      |> form("#requirements-form", %{"requirements" => @written})
      |> render_submit()

      {:ok, reopened, _html} = live(conn, feature_path(project, feature))

      for {key, body} <- @written do
        assert reopened |> element(part_selector(key)) |> render() =~ body
      end
    end

    test "a participant saves the same form as the owner [AC-10]", %{
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
      |> form("#requirements-form", %{"requirements" => @written})
      |> render_submit()

      assert [_created, saved] = revisions(feature.specification_id)
      assert GuidedRequirements.parse(saved.requirements_document) == @written
      assert saved.actor_ref == context.identity.account.id
    end
  end

  describe "a revision written by somebody else" do
    test "is refused with a reload notice, and the head is left where it is", %{
      conn: conn,
      workspace: workspace,
      project: project,
      feature: feature,
      account: account
    } do
      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(feature_path(project, feature))

      competing = append_elsewhere(workspace, project, feature, "Somebody else got here first.")

      view
      |> form("#requirements-form", %{"requirements" => @written})
      |> render_submit()

      notice = view |> element("[data-requirements-error]") |> render()

      assert notice =~ "Reload the page"
      refute notice =~ "—"

      # Two revisions, not three: the creation and the competing save.
      assert [_created, head] = revisions(feature.specification_id)
      assert head.id == competing.id

      assert {:ok, current} =
               SpecificationStore.get_current(workspace, project.id, feature.specification_id)

      assert current.revision.id == competing.id

      assert GuidedRequirements.parse(current.revision.requirements_document)["outcome"] ==
               "Somebody else got here first."

      # The refused words stay in the form so nobody has to type them again.
      assert view |> element(part_selector("outcome")) |> render() =~ @written["outcome"]
    end
  end

  describe "the documents the coding agent owns" do
    test "are carried forward unchanged across every save the form makes", %{
      conn: conn,
      project: project,
      feature: feature,
      account: account
    } do
      assert [created] = revisions(feature.specification_id)

      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(feature_path(project, feature))

      view
      |> form("#requirements-form", %{"requirements" => @written})
      |> render_submit()

      view
      |> form("#requirements-form", %{
        "requirements" => %{@written | "rules" => "An empty search shows nothing."}
      })
      |> render_submit()

      assert [^created, first, second] = revisions(feature.specification_id)

      for revision <- [first, second] do
        assert revision.design_document == created.design_document
        assert revision.tasks_document == created.tasks_document
      end

      assert GuidedRequirements.parse(second.requirements_document)["rules"] ==
               "An empty search shows nothing."
    end
  end

  defp part_selector(key), do: "[data-requirements-part=\"#{key}\"]"

  defp revisions(specification_id) do
    SpecificationRevision
    |> where([revision], revision.specification_id == ^specification_id)
    |> order_by([revision], asc: revision.sequence)
    |> Repo.all()
  end

  # A save nobody on this page made: the same store call another session, or the
  # run's own answer write-back, would use.
  defp append_elsewhere(workspace, project, feature, outcome) do
    {:ok, current} =
      SpecificationStore.get_current(workspace, project.id, feature.specification_id)

    {:ok, appended} =
      SpecificationStore.append_revision(
        workspace,
        project.id,
        feature.specification_id,
        current.revision.id,
        %{
          revision_id: Ecto.UUID.generate(),
          documents: %{
            requirements: GuidedRequirements.render(%{"outcome" => outcome}),
            design: current.revision.design_document,
            tasks: current.revision.tasks_document
          }
        }
      )

    appended.revision
  end

  defp feature_path(project, feature), do: ~p"/projects/#{project.id}/features/#{feature.id}"

  defp log_in_hosted(conn, hosted_identity) do
    {:ok, _session, cookie} = Sessions.create(hosted_identity, %{})

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(SessionCookie.session_key(), cookie.value)
  end
end
