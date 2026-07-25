defmodule SddOrchestratorWeb.DeviceSetupLiveTest do
  @moduledoc """
  Proof for the device-setup placeholder the storage step hands off to: it
  renders for a valid workspace-scoped attempt, offers a return to the same
  storage step (preserving the attempt), refuses unknown, malformed, or
  cross-workspace attempts, and requires an authenticated session. The real
  device setup replaces this placeholder in specs/02.
  """
  use SddOrchestratorWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias SddOrchestrator.AccountsFixtures
  alias SddOrchestrator.ProjectsFixtures

  describe "authenticated" do
    setup %{conn: conn} do
      %{conn: conn, account: account} = register_and_log_in_account(%{conn: conn})
      workspace = ProjectsFixtures.workspace_fixture(account)
      attempt = ProjectsFixtures.attempt_with_repository(workspace)
      %{conn: conn, workspace: workspace, attempt: attempt}
    end

    test "renders and returns to the same storage step", %{conn: conn, attempt: attempt} do
      {:ok, view, html} = live(conn, ~p"/onboarding/device-setup/#{attempt.id}")

      assert html =~ ~s(data-screen="device-setup")
      assert has_element?(view, "a[href='/onboarding/storage/#{attempt.id}']")
    end

    test "routes back to the catalog for an unknown attempt", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/projects"}}} =
               live(conn, ~p"/onboarding/device-setup/#{Ecto.UUID.generate()}")
    end

    test "never resolves another workspace's attempt", %{conn: conn} do
      foreign = ProjectsFixtures.workspace_fixture(AccountsFixtures.account_fixture())
      foreign_attempt = ProjectsFixtures.attempt_with_repository(foreign)

      assert {:error, {:live_redirect, %{to: "/projects"}}} =
               live(conn, ~p"/onboarding/device-setup/#{foreign_attempt.id}")
    end
  end

  test "requires an authenticated session", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} =
             live(conn, ~p"/onboarding/device-setup/#{Ecto.UUID.generate()}")
  end
end
