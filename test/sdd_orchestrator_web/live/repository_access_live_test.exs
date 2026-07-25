defmodule SddOrchestratorWeb.RepositoryAccessLiveTest do
  @moduledoc """
  Proof for the repository-access placeholder route the catalog hands off to: it
  renders for a valid workspace-scoped attempt, refuses unknown, malformed, or
  cross-workspace attempts by routing back to the catalog, and requires an
  authenticated session.
  """
  use SddOrchestratorWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias SddOrchestrator.AccountsFixtures
  alias SddOrchestrator.Projects
  alias SddOrchestrator.ProjectsFixtures

  describe "authenticated" do
    setup %{conn: conn} do
      %{conn: conn, account: account} = register_and_log_in_account(%{conn: conn})
      workspace = ProjectsFixtures.workspace_fixture(account)
      {:ok, attempt} = Projects.start_onboarding_attempt(workspace)
      %{conn: conn, account: account, workspace: workspace, attempt: attempt}
    end

    test "renders the placeholder for a valid attempt", %{conn: conn, attempt: attempt} do
      {:ok, _view, html} = live(conn, ~p"/onboarding/repository-access/#{attempt.id}")

      assert html =~ "Repository access"
      assert html =~ ~s(data-screen="repository-access")
    end

    test "routes back to the catalog for an unknown attempt", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/projects"}}} =
               live(conn, ~p"/onboarding/repository-access/#{Ecto.UUID.generate()}")
    end

    test "routes back to the catalog for a malformed attempt id", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/projects"}}} =
               live(conn, ~p"/onboarding/repository-access/not-a-uuid")
    end

    test "never resolves another workspace's attempt", %{conn: conn} do
      foreign = ProjectsFixtures.workspace_fixture(AccountsFixtures.account_fixture())
      {:ok, foreign_attempt} = Projects.start_onboarding_attempt(foreign)

      assert {:error, {:live_redirect, %{to: "/projects"}}} =
               live(conn, ~p"/onboarding/repository-access/#{foreign_attempt.id}")
    end
  end

  test "requires an authenticated session", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} =
             live(conn, ~p"/onboarding/repository-access/#{Ecto.UUID.generate()}")
  end
end
