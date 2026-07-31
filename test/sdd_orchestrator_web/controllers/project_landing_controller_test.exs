defmodule SddOrchestratorWeb.ProjectLandingControllerTest do
  @moduledoc """
  Proof for the project landing decision (specs/07 Task 53, AC-48).

  A project's address is not a screen. It resolves to the board when the project
  is set up — its repository connection and its hosted storage both exist — and
  to the overview while either is still missing, because the overview is the
  screen that says what setup is left.

  Who is asking is deliberately not part of the decision. The board fails closed
  on its own mount, so the landing never has to guess at access, and a member's
  missing display label — the thing the first implementation accidentally made a
  precondition for the board — cannot divert either outcome.
  """
  use SddOrchestratorWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias SddOrchestrator.HostedAccess.SessionCookie
  alias SddOrchestrator.HostedAccessFixtures
  alias SddOrchestrator.Participation
  alias SddOrchestrator.ParticipationFixtures
  alias SddOrchestrator.ProjectsFixtures
  alias SddOrchestrator.Repo

  describe "a configured project" do
    test "sends its owner to the feature board, which does not then refuse them", %{conn: conn} do
      %{project: project, account: account} = configured_project()

      conn = conn |> log_in_account(account) |> get(~p"/projects/#{project.id}")

      assert redirected_to(conn) == "/projects/#{project.id}/features"

      # The landing is only worth anything if the destination lets them in.
      assert {:ok, _view, html} =
               build_conn() |> log_in_account(account) |> live(redirected_to(conn))

      assert html =~ "data-screen=\"feature-board\""
    end

    test "sends a participant on their hosted session to the feature board", %{conn: conn} do
      %{project: project} = configured_project()
      participant = participant_of(project)

      conn = conn |> hosted(participant) |> get(~p"/projects/#{project.id}")

      assert redirected_to(conn) == "/projects/#{project.id}/features"

      assert {:ok, _view, html} = build_conn() |> hosted(participant) |> live(redirected_to(conn))
      assert html =~ "data-screen=\"feature-board\""
    end
  end

  describe "a member with no display label" do
    test "still reaches the board of a configured project (specs/08 AC-40)", %{conn: conn} do
      %{project: project, account: account} = configured_project()

      # Registration establishes the owner's label with the project. Remove it to
      # reproduce exactly the state the old participation test read as "not set
      # up", which sent the owner to an overview with nothing left to say.
      project.id |> Participation.owner_profile() |> Repo.delete!()
      refute Participation.owner_profile_established?(project.id)

      conn = conn |> log_in_account(account) |> get(~p"/projects/#{project.id}")

      assert redirected_to(conn) == "/projects/#{project.id}/features"

      assert {:ok, _view, html} =
               build_conn() |> log_in_account(account) |> live(redirected_to(conn))

      assert html =~ "data-screen=\"feature-board\""
    end

    test "lands in the same place once a label is saved", %{conn: conn} do
      %{project: project, account: account} = configured_project()
      project.id |> Participation.owner_profile() |> Repo.delete!()

      assert conn
             |> log_in_account(account)
             |> get(~p"/projects/#{project.id}")
             |> redirected_to() == "/projects/#{project.id}/features"

      {:ok, _profile} = Participation.save_owner_profile(project, account.id, "Ada Lovelace")

      assert build_conn()
             |> log_in_account(account)
             |> get(~p"/projects/#{project.id}")
             |> redirected_to() == "/projects/#{project.id}/features"
    end
  end

  describe "a project that is not set up yet" do
    test "sends its owner to the overview instead of the board", %{conn: conn} do
      %{project: project, account: account} = ParticipationFixtures.hosted_project_fixture()

      conn = conn |> log_in_account(account) |> get(~p"/projects/#{project.id}")

      assert redirected_to(conn) == "/projects/#{project.id}/overview"
    end

    test "counts a missing repository connection as not set up", %{conn: conn} do
      %{project: project, account: account} = configured_project()

      project
      |> Repo.preload(:repository_connection)
      |> Map.fetch!(:repository_connection)
      |> Repo.delete!()

      conn = conn |> log_in_account(account) |> get(~p"/projects/#{project.id}")

      assert redirected_to(conn) == "/projects/#{project.id}/overview"
    end

    test "counts missing storage as not set up", %{conn: conn} do
      %{project: project, account: account} = configured_project()

      project |> Repo.preload(:hosted_storage) |> Map.fetch!(:hosted_storage) |> Repo.delete!()

      conn = conn |> log_in_account(account) |> get(~p"/projects/#{project.id}")

      assert redirected_to(conn) == "/projects/#{project.id}/overview"
    end

    test "sends a visitor with no session at all to the overview", %{conn: conn} do
      %{project: project} = ParticipationFixtures.hosted_project_fixture()

      conn = get(conn, ~p"/projects/#{project.id}")

      assert redirected_to(conn) == "/projects/#{project.id}/overview"
    end
  end

  describe "fails closed" do
    test "leaves a hosted identity that is not a member refused at the board", %{conn: conn} do
      %{project: project} = configured_project()
      outsider = ParticipationFixtures.invited_identity_fixture()

      conn = conn |> hosted(outsider) |> get(~p"/projects/#{project.id}")

      # The landing does not adjudicate access, so it sends them the same way it
      # sends everyone; the board is what refuses them, and it discloses nothing.
      assert redirected_to(conn) == "/projects/#{project.id}/features"

      assert {:error, {:live_redirect, %{to: "/projects"}}} =
               build_conn() |> hosted(outsider) |> live(~p"/projects/#{project.id}/features")
    end

    test "leaves a visitor with no session refused at the board", %{conn: conn} do
      %{project: project} = configured_project()

      conn = get(conn, ~p"/projects/#{project.id}")

      assert redirected_to(conn) == "/projects/#{project.id}/features"

      assert {:error, {:live_redirect, %{to: "/projects"}}} =
               build_conn() |> live(~p"/projects/#{project.id}/features")
    end

    test "sends a malformed project address back to the catalog without raising", %{conn: conn} do
      %{account: account} = configured_project()

      conn = conn |> log_in_account(account) |> get("/projects/not-a-uuid")

      assert redirected_to(conn) == "/projects"
    end

    test "never lands a member of one project inside another project", %{conn: conn} do
      %{account: account} = configured_project()
      %{project: other_project} = configured_project()

      conn = conn |> log_in_account(account) |> get(~p"/projects/#{other_project.id}")

      # The redirect stays on the address that was asked for and carries nothing
      # from the project this account actually belongs to.
      assert redirected_to(conn) == "/projects/#{other_project.id}/features"
      refute conn.resp_body =~ other_project.name

      assert {:error, {:live_redirect, %{to: "/projects"}}} =
               build_conn()
               |> log_in_account(account)
               |> live(~p"/projects/#{other_project.id}/features")
    end

    test "answers the same for a member, a stranger, and nobody", %{conn: conn} do
      %{project: project, account: account} = configured_project()
      stranger = ParticipationFixtures.invited_identity_fixture()

      member = conn |> log_in_account(account) |> get(~p"/projects/#{project.id}")
      outsider = build_conn() |> hosted(stranger) |> get(~p"/projects/#{project.id}")
      anonymous = build_conn() |> get(~p"/projects/#{project.id}")

      # The decision is about the project, so no redirect can be read as evidence
      # of who belongs to it.
      for answer <- [member, outsider, anonymous] do
        assert answer.status == member.status
        assert redirected_to(answer) == redirected_to(member)
        refute answer.resp_body =~ project.name
      end
    end

    test "answers a project that does not exist exactly as one that is not set up", %{conn: conn} do
      %{account: account} = configured_project()
      %{project: unconfigured} = ParticipationFixtures.hosted_project_fixture()
      unknown = Ecto.UUID.generate()

      missing = conn |> log_in_account(account) |> get(~p"/projects/#{unknown}")
      present = build_conn() |> log_in_account(account) |> get(~p"/projects/#{unconfigured.id}")

      assert missing.status == present.status
      assert redirected_to(missing) == "/projects/#{unknown}/overview"
      assert redirected_to(present) == "/projects/#{unconfigured.id}/overview"
      refute missing.resp_body =~ unconfigured.name
    end
  end

  # A project that went through the real registration transaction, so its
  # repository connection and hosted storage exist because they were created the
  # way the product creates them.
  defp configured_project do
    owner = HostedAccessFixtures.hosted_identity_fixture()
    project = ProjectsFixtures.registered_project(owner.personal_workspace)

    %{owner: owner, account: owner.account, workspace: owner.personal_workspace, project: project}
  end

  # One current participant of the project, with the display label a real
  # acceptance would have recorded.
  defp participant_of(project) do
    identity = ParticipationFixtures.invited_identity_fixture()
    ParticipationFixtures.participant_fixture(project, identity.hosted_identity)

    ParticipationFixtures.member_profile_fixture(project, identity.account, %{
      role: "participant",
      display_name: ParticipationFixtures.unique_display_name("Member")
    })

    identity
  end

  defp hosted(conn, identity) do
    access =
      HostedAccessFixtures.verified_hosted_session_fixture(%{
        email: identity.external_identity.display_identifier
      })

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(SessionCookie.session_key(), access.session_cookie.value)
  end
end
