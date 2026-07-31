defmodule SddOrchestratorWeb.E2EBootstrapControllerTest do
  @moduledoc """
  Proof for the browser-harness bootstrap.

  Two things have to hold. The endpoint must actually establish the sessions
  the browser suite needs, or the authenticated matrices it unblocks are not
  really being proven. And it must be impossible to reach in production, which
  is asserted here in both of the ways it is prevented: the runtime guard
  answers `404` when the flag is off, and no production configuration sets the
  flag that compiles the route in at all.
  """
  # Not async: the delivered-credential scenario switches the mailer to the
  # local sink for the whole application.
  use SddOrchestratorWeb.ConnCase, async: false

  alias SddOrchestrator.Delivery.Feature
  alias SddOrchestrator.HostedAccess.SessionCookie
  alias SddOrchestrator.Participation
  alias SddOrchestrator.Participation.{InvitationProof, Invitations}
  alias SddOrchestrator.Projects
  alias SddOrchestrator.Projects.Project
  alias SddOrchestrator.Repo

  describe "production exclusion" do
    test "answers 404 when the harness flag is off", %{conn: conn} do
      original = Application.get_env(:sdd_orchestrator, :e2e_bootstrap)
      Application.put_env(:sdd_orchestrator, :e2e_bootstrap, false)
      on_exit(fn -> Application.put_env(:sdd_orchestrator, :e2e_bootstrap, original) end)

      conn = get(conn, ~p"/_e2e/session?scenario=project_owner")

      assert response(conn, 404)
      refute get_session(conn, :session_token)
    end

    test "no production configuration sets the flag that compiles the route in" do
      config = Config.Reader.read!("config/config.exs", env: :prod)

      refute config |> Keyword.fetch!(:sdd_orchestrator) |> Keyword.get(:e2e_bootstrap)
    end

    test "the flag is what the router gates the route on" do
      # The route exists here only because the test configuration sets the same
      # key the production configuration leaves unset.
      assert Application.get_env(:sdd_orchestrator, :e2e_bootstrap)

      assert Enum.any?(
               SddOrchestratorWeb.Router.__routes__(),
               &(&1.path == "/_e2e/session")
             )
    end
  end

  describe "unknown scenario" do
    test "is rejected without establishing a session", %{conn: conn} do
      conn = get(conn, ~p"/_e2e/session?scenario=nope")

      assert json_response(conn, 400)
      refute get_session(conn, :session_token)
    end
  end

  describe "project_owner" do
    test "establishes the application session for the project owner", %{conn: conn} do
      conn = get(conn, ~p"/_e2e/session?scenario=project_owner")

      assert %{"project_id" => project_id, "owner_name" => owner_name} = json_response(conn, 200)
      assert get_session(conn, :session_token)
      assert Participation.owner_profile(project_id).display_name == owner_name

      # The established session reaches the authenticated screen it is for.
      assert conn
             |> get(~p"/projects/#{project_id}/participation")
             |> html_response(200) =~ "participation-settings"
    end

    test "can leave the owner label unset so the prerequisite is drivable", %{conn: conn} do
      conn = get(conn, ~p"/_e2e/session?scenario=project_owner&owner_profile=false")

      assert %{"project_id" => project_id, "owner_name" => nil} = json_response(conn, 200)
      refute Participation.owner_profile(project_id)
    end
  end

  describe "project_member" do
    test "seeds a real participant and signs the owner in", %{conn: conn} do
      conn = get(conn, ~p"/_e2e/session?scenario=project_member")

      assert %{
               "project_id" => project_id,
               "participant_name" => participant_name,
               "participant_email" => participant_email,
               "pending_email" => pending_email
             } = json_response(conn, 200)

      assert get_session(conn, :session_token)
      assert [participant] = Participation.active_participants(project_id)
      assert participant.state == "active"
      assert participant_email =~ "@example.com"

      members = Participation.members(Repo.get!(Project, project_id), :owner, nil)
      assert Enum.any?(members, &(&1.display_name == participant_name))

      assert [pending] =
               project_id |> Invitations.list() |> Enum.filter(&(&1.status == "pending"))

      assert pending.delivery_email == pending_email
    end

    test "signs the participant in through the hosted session instead", %{conn: conn} do
      conn = get(conn, ~p"/_e2e/session?scenario=project_member&as=participant")

      assert %{"project_id" => project_id} = json_response(conn, 200)
      refute get_session(conn, :session_token)
      assert get_session(conn, SessionCookie.session_key())

      assert conn
             |> get(~p"/projects/#{project_id}/participation")
             |> html_response(200) =~ "participant-view"
    end
  end

  describe "invitation" do
    setup :use_local_mailbox

    test "returns the credential that was actually delivered", %{conn: conn} do
      conn = get(conn, ~p"/_e2e/session?scenario=invitation")

      assert %{"invitation_id" => invitation_id, "invitation_path" => path} =
               json_response(conn, 200)

      assert path =~ "/projects/invitations/#{invitation_id}/accept?token="
      refute get_session(conn, SessionCookie.session_key())

      # The returned link is the real credential: it opens the invitation.
      token =
        path |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("token")

      assert {:ok, _opened} = InvitationProof.open(invitation_id, token)
    end

    test "can hold the browser as the invited address", %{conn: conn} do
      conn = get(conn, ~p"/_e2e/session?scenario=invitation&as=invited")

      assert %{"invitation_id" => invitation_id} = json_response(conn, 200)
      assert get_session(conn, SessionCookie.session_key())

      assert conn
             |> get(~p"/projects/invitations/#{invitation_id}/accept")
             |> html_response(200) =~ "proof-complete"
    end

    test "can hold the browser as an unrelated identity", %{conn: conn} do
      conn = get(conn, ~p"/_e2e/session?scenario=invitation&as=other")

      assert %{"invitation_path" => path} = json_response(conn, 200)
      assert get_session(conn, SessionCookie.session_key())

      assert conn |> get(path) |> html_response(200) =~
               "identity-change-warning"
    end
  end

  describe "features" do
    test "seeds an empty board by default", %{conn: conn} do
      conn = get(conn, ~p"/_e2e/session?scenario=features")

      assert %{"project_id" => project_id, "features" => features} = json_response(conn, 200)
      assert features == %{}
      assert Feature |> Repo.all() |> Enum.filter(&(&1.project_id == project_id)) == []
    end

    test "seeds one feature in every column through the real transition table", %{conn: conn} do
      conn = get(conn, ~p"/_e2e/session?scenario=features&populated=true")

      assert %{"features" => features} = json_response(conn, 200)
      assert features |> Map.keys() |> Enum.sort() == Enum.sort(Feature.columns())

      for {column, id} <- features do
        feature = Repo.get!(Feature, id)
        assert feature.lifecycle_column == column
      end

      # The in-development card carries a visible status; the later columns do not.
      assert Repo.get!(Feature, features["in_development"]).status == "blocked"
      assert Repo.get!(Feature, features["done"]).status == "none"
    end

    test "seeds a project that is really set up only when asked to", %{conn: conn} do
      assert %{"project_id" => bare_id} =
               conn |> get(~p"/_e2e/session?scenario=features") |> json_response(200)

      assert %{"project_id" => configured_id} =
               build_conn()
               |> get(~p"/_e2e/session?scenario=features&configured=true")
               |> json_response(200)

      # The browser navigation matrix needs both landings to be real, so the
      # difference has to be the repository connection and storage themselves
      # rather than a flag the harness reports about itself.
      refute Projects.configured?(bare_id)
      assert Projects.configured?(configured_id)
    end
  end

  # The delivered-credential path reads the message out of the local sink, the
  # same store the development server writes to.
  defp use_local_mailbox(_context) do
    original = Application.get_env(:sdd_orchestrator, SddOrchestrator.Mailer)
    Application.put_env(:sdd_orchestrator, SddOrchestrator.Mailer, adapter: Swoosh.Adapters.Local)
    on_exit(fn -> Application.put_env(:sdd_orchestrator, SddOrchestrator.Mailer, original) end)
    :ok
  end
end
