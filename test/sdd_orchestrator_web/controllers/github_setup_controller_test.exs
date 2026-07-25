defmodule SddOrchestratorWeb.GitHubSetupControllerTest do
  @moduledoc """
  Proof for the GitHub App installation handoff and validated return. The install
  route binds a one-time state to the browser and redirects to the public app
  installation page; the setup return only routes back to the attempt's
  repository-access re-check and never grants access or creates a project from
  its parameters. Both routes require an authenticated session and only act on an
  attempt owned by the current workspace.
  """
  use SddOrchestratorWeb.ConnCase, async: true

  alias SddOrchestrator.Projects
  alias SddOrchestrator.ProjectsFixtures

  setup %{conn: conn} do
    %{conn: conn, account: account} = register_and_log_in_account(%{conn: conn})
    workspace = ProjectsFixtures.workspace_fixture(account)
    {:ok, attempt} = Projects.start_onboarding_attempt(workspace)
    %{conn: conn, account: account, workspace: workspace, attempt: attempt}
  end

  describe "GET /github/install" do
    test "binds a one-time state and redirects to the public app installation page", %{
      conn: conn,
      attempt: attempt
    } do
      conn = get(conn, ~p"/github/install?#{[attempt_id: attempt.id]}")

      assert redirected_to(conn) =~ "https://github.com/apps/orchestra-workflow/installations/new"
      assert redirected_to(conn) =~ "state="

      state = get_session(conn, :github_install_state)
      assert is_binary(state) and byte_size(state) > 0
      assert get_session(conn, :github_install_attempt) == attempt.id
    end

    test "routes an unknown attempt back to the catalog", %{conn: conn} do
      conn = get(conn, ~p"/github/install?#{[attempt_id: Ecto.UUID.generate()]}")
      assert redirected_to(conn) == ~p"/projects"
    end

    test "never targets another workspace's attempt", %{conn: conn} do
      foreign =
        ProjectsFixtures.workspace_fixture(SddOrchestrator.AccountsFixtures.account_fixture())

      {:ok, foreign_attempt} = Projects.start_onboarding_attempt(foreign)

      conn = get(conn, ~p"/github/install?#{[attempt_id: foreign_attempt.id]}")
      assert redirected_to(conn) == ~p"/projects"
    end
  end

  describe "GET /github/setup" do
    test "routes back to the attempt's repository-access re-check and consumes the state", %{
      conn: conn,
      attempt: attempt
    } do
      conn =
        conn
        |> Plug.Conn.put_session(:github_install_state, "s-123")
        |> Plug.Conn.put_session(:github_install_attempt, attempt.id)
        |> get(
          ~p"/github/setup?#{[state: "s-123", installation_id: "999", setup_action: "install"]}"
        )

      assert redirected_to(conn) == ~p"/onboarding/repository-access/#{attempt.id}"
      # The one-time state is consumed.
      assert is_nil(get_session(conn, :github_install_state))
    end

    test "still re-checks (never trusts params) even on a state mismatch", %{
      conn: conn,
      attempt: attempt
    } do
      conn =
        conn
        |> Plug.Conn.put_session(:github_install_state, "expected")
        |> Plug.Conn.put_session(:github_install_attempt, attempt.id)
        |> get(~p"/github/setup?#{[state: "forged", installation_id: "999"]}")

      # Safe: the destination re-reads access with the user's token; params alone
      # grant nothing.
      assert redirected_to(conn) == ~p"/onboarding/repository-access/#{attempt.id}"
    end

    test "routes to the catalog when there is no bound attempt", %{conn: conn} do
      conn = get(conn, ~p"/github/setup?#{[state: "whatever", installation_id: "1"]}")
      assert redirected_to(conn) == ~p"/projects"
    end
  end

  describe "authentication" do
    test "install requires a session", %{attempt: attempt} do
      conn = get(build_conn(), ~p"/github/install?#{[attempt_id: attempt.id]}")
      assert redirected_to(conn) == ~p"/"
    end

    test "setup requires a session" do
      conn = get(build_conn(), ~p"/github/setup?#{[state: "x"]}")
      assert redirected_to(conn) == ~p"/"
    end
  end
end
