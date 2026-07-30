defmodule SddOrchestratorWeb.ProjectLandingControllerTest do
  @moduledoc """
  Proof for the project landing decision (specs/07 Task 53, AC-48).

  A project's address is not a screen. It resolves to the board when the acting
  person is a current member of a configured project, and to the overview in
  every other case — including the one that matters most, a freshly registered
  project whose owner has not saved a project display name yet and therefore
  cannot use the board at all.

  The failing cases all land in the same place, so nobody learns from the
  redirect whether the project exists or whether they used to belong to it.
  """
  use SddOrchestratorWeb.ConnCase, async: true

  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.HostedAccess.SessionCookie
  alias SddOrchestrator.HostedAccessFixtures
  alias SddOrchestrator.Participation
  alias SddOrchestrator.ParticipationFixtures

  describe "a configured project" do
    test "sends its owner to the feature board", %{conn: conn} do
      %{project: project, account: account} = DeliveryFixtures.delivery_project_fixture()

      conn = conn |> log_in_account(account) |> get(~p"/projects/#{project.id}")

      assert redirected_to(conn) == "/projects/#{project.id}/features"
    end

    test "sends a participant on their hosted session to the feature board", %{conn: conn} do
      %{project: project, identity: identity} = DeliveryFixtures.delivery_project_fixture()

      conn = conn |> hosted(identity) |> get(~p"/projects/#{project.id}")

      assert redirected_to(conn) == "/projects/#{project.id}/features"
    end
  end

  describe "a project that is not configured yet" do
    test "sends its owner to the overview while no owner display name exists", %{conn: conn} do
      %{project: project, account: account} = ParticipationFixtures.hosted_project_fixture()

      refute Participation.owner_profile_established?(project.id)

      conn = conn |> log_in_account(account) |> get(~p"/projects/#{project.id}")

      assert redirected_to(conn) == "/projects/#{project.id}/overview"
    end

    test "sends the same owner to the board once setup is complete", %{conn: conn} do
      %{project: project, account: account} = ParticipationFixtures.hosted_project_fixture()

      assert conn
             |> log_in_account(account)
             |> get(~p"/projects/#{project.id}")
             |> redirected_to() ==
               "/projects/#{project.id}/overview"

      {:ok, _profile} = Participation.save_owner_profile(project, account.id, "Ada Lovelace")

      assert build_conn()
             |> log_in_account(account)
             |> get(~p"/projects/#{project.id}")
             |> redirected_to() == "/projects/#{project.id}/features"
    end
  end

  describe "fails closed" do
    test "sends a hosted identity that is not a member to the overview", %{conn: conn} do
      %{project: project} = DeliveryFixtures.delivery_project_fixture()
      outsider = ParticipationFixtures.invited_identity_fixture()

      conn = conn |> hosted(outsider) |> get(~p"/projects/#{project.id}")

      assert redirected_to(conn) == "/projects/#{project.id}/overview"
    end

    test "sends a visitor with no session at all to the overview", %{conn: conn} do
      %{project: project} = DeliveryFixtures.delivery_project_fixture()

      conn = get(conn, ~p"/projects/#{project.id}")

      assert redirected_to(conn) == "/projects/#{project.id}/overview"
    end

    test "sends a malformed project address back to the catalog without raising", %{conn: conn} do
      %{account: account} = DeliveryFixtures.delivery_project_fixture()

      conn = conn |> log_in_account(account) |> get("/projects/not-a-uuid")

      assert redirected_to(conn) == "/projects"
    end

    test "never lands a member of one project on another project's board", %{conn: conn} do
      %{account: account} = DeliveryFixtures.delivery_project_fixture()
      %{project: other_project} = DeliveryFixtures.delivery_project_fixture()

      conn = conn |> log_in_account(account) |> get(~p"/projects/#{other_project.id}")

      redirect = redirected_to(conn)

      assert redirect == "/projects/#{other_project.id}/overview"
      refute redirect =~ "/features"
    end

    test "answers a project that does not exist exactly as one it may not open", %{conn: conn} do
      %{account: account} = DeliveryFixtures.delivery_project_fixture()
      %{project: other_project} = DeliveryFixtures.delivery_project_fixture()
      unknown = Ecto.UUID.generate()

      missing = conn |> log_in_account(account) |> get(~p"/projects/#{unknown}")
      refused = build_conn() |> log_in_account(account) |> get(~p"/projects/#{other_project.id}")

      # Same status, same destination shape, and nothing rendered: neither answer
      # says whether the project exists.
      assert missing.status == refused.status
      assert redirected_to(missing) == "/projects/#{unknown}/overview"
      assert redirected_to(refused) == "/projects/#{other_project.id}/overview"
      refute missing.resp_body =~ other_project.name
      refute refused.resp_body =~ other_project.name
    end
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
