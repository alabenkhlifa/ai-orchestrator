defmodule SddOrchestratorWeb.StorageSelectionLiveTest do
  @moduledoc """
  Proof for the storage-selection placeholder route the repository picker hands
  off to: it renders for a valid workspace-scoped attempt (showing the selected
  repository), refuses unknown, malformed, or cross-workspace attempts by routing
  back to the catalog, and requires an authenticated session. The real storage
  step replaces this placeholder in the storage-selection task.
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

      {:ok, attempt} =
        Projects.select_repository(workspace, attempt.id, %{
          id: 101,
          owner: "octo",
          name: "example",
          full_name: "octo/example",
          private: false,
          visibility: "public",
          html_url: "https://github.com/octo/example",
          organization: nil
        })

      %{conn: conn, workspace: workspace, attempt: attempt}
    end

    test "renders the placeholder with the selected repository", %{conn: conn, attempt: attempt} do
      {:ok, _view, html} = live(conn, ~p"/onboarding/storage/#{attempt.id}")

      assert html =~ ~s(data-screen="storage-selection")
      assert html =~ "Where should your project work be saved?"
      assert html =~ "octo/example"
    end

    test "routes back to the catalog for an unknown attempt", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/projects"}}} =
               live(conn, ~p"/onboarding/storage/#{Ecto.UUID.generate()}")
    end

    test "routes back to the catalog for a malformed attempt id", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/projects"}}} =
               live(conn, ~p"/onboarding/storage/not-a-uuid")
    end

    test "never resolves another workspace's attempt", %{conn: conn} do
      foreign = ProjectsFixtures.workspace_fixture(AccountsFixtures.account_fixture())
      {:ok, foreign_attempt} = Projects.start_onboarding_attempt(foreign)

      assert {:error, {:live_redirect, %{to: "/projects"}}} =
               live(conn, ~p"/onboarding/storage/#{foreign_attempt.id}")
    end
  end

  test "requires an authenticated session", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} =
             live(conn, ~p"/onboarding/storage/#{Ecto.UUID.generate()}")
  end
end
