defmodule SddOrchestratorWeb.ProjectConfirmationLiveTest do
  @moduledoc """
  Proof for the confirmation placeholder the storage step hands off to: it renders
  the selected repository and storage mode for a ready attempt, sends an attempt
  missing a repository or storage mode back to the storage step, refuses unknown
  or cross-workspace attempts, and requires an authenticated session. The real
  confirmation and creation surface replaces this placeholder in the confirmation
  task.
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
      %{conn: conn, workspace: workspace}
    end

    test "renders the selected repository and storage mode", %{conn: conn, workspace: workspace} do
      attempt = ProjectsFixtures.attempt_with_repository(workspace)
      {:ok, attempt} = Projects.select_storage_mode(workspace, attempt.id, "hosted")

      {:ok, _view, html} = live(conn, ~p"/onboarding/confirm/#{attempt.id}")

      assert html =~ ~s(data-screen="project-confirmation")
      assert html =~ "octo/example"
      assert html =~ "In my SDD Orchestrator account"
    end

    test "sends an attempt without a storage mode back to the storage step", %{
      conn: conn,
      workspace: workspace
    } do
      attempt = ProjectsFixtures.attempt_with_repository(workspace)

      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, ~p"/onboarding/confirm/#{attempt.id}")

      assert to == "/onboarding/storage/#{attempt.id}"
    end

    test "routes back to the catalog for an unknown attempt", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/projects"}}} =
               live(conn, ~p"/onboarding/confirm/#{Ecto.UUID.generate()}")
    end

    test "never resolves another workspace's attempt", %{conn: conn, workspace: _workspace} do
      foreign = ProjectsFixtures.workspace_fixture(AccountsFixtures.account_fixture())
      foreign_attempt = ProjectsFixtures.attempt_with_repository(foreign)
      {:ok, _} = Projects.select_storage_mode(foreign, foreign_attempt.id, "hosted")

      assert {:error, {:live_redirect, %{to: "/projects"}}} =
               live(conn, ~p"/onboarding/confirm/#{foreign_attempt.id}")
    end
  end

  test "requires an authenticated session", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} =
             live(conn, ~p"/onboarding/confirm/#{Ecto.UUID.generate()}")
  end
end
