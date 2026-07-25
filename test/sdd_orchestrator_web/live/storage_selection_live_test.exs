defmodule SddOrchestratorWeb.StorageSelectionLiveTest do
  @moduledoc """
  Proof for the storage-selection step. Covers the question and explanation, both
  choices always visible, the unavailable device mode explaining its prerequisite
  with a non-selecting setup action, continuation blocked until an available mode
  is explicitly chosen (no silent default), device availability refreshing from a
  recorded receipt without auto-selection, and that no project is created on any
  path. Mount is workspace-scoped and requires a selected repository.
  """
  use SddOrchestratorWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias SddOrchestrator.AccountsFixtures
  alias SddOrchestrator.Projects
  alias SddOrchestrator.ProjectsFixtures
  alias SddOrchestrator.ProjectStorage.DeviceStorageReceipt

  defp setup_account(conn) do
    %{conn: conn, account: account} = register_and_log_in_account(%{conn: conn})
    workspace = ProjectsFixtures.workspace_fixture(account)
    %{conn: conn, account: account, workspace: workspace}
  end

  describe "storage step (device unavailable)" do
    setup %{conn: conn} do
      ctx = setup_account(conn)
      attempt = ProjectsFixtures.attempt_with_repository(ctx.workspace)
      Map.merge(ctx, %{attempt: attempt})
    end

    test "asks the question, explains the repository stays put, and shows both choices (AC-24)",
         %{conn: conn, attempt: attempt} do
      {:ok, _view, html} = live(conn, ~p"/onboarding/storage/#{attempt.id}")

      assert html =~ ~s(data-screen="storage-selection")
      assert html =~ "Where should your project work be saved?"
      assert html =~ "stays exactly where it is"
      assert html =~ "octo/example"
      assert html =~ "In my SDD Orchestrator account"
      assert html =~ "On this device"
    end

    test "keeps the unavailable device mode visible with a non-selecting setup action (AC-25)", %{
      conn: conn,
      attempt: attempt,
      workspace: workspace
    } do
      {:ok, view, html} = live(conn, ~p"/onboarding/storage/#{attempt.id}")

      assert has_element?(view, "#storage-device[aria-disabled=true]")
      assert html =~ "needs a quick one-time setup"
      assert has_element?(view, "button[phx-click=setup_device]")

      # Trying to select the disabled device mode selects nothing and creates nothing.
      view |> element("#storage-device") |> render_click()
      refute has_element?(view, "#storage-device[aria-checked=true]")
      assert is_nil(Projects.get_onboarding_attempt(workspace, attempt.id).storage_mode)
      refute Projects.has_projects?(workspace)
    end

    test "continuation is blocked until an available mode is chosen (AC-27)", %{
      conn: conn,
      attempt: attempt,
      workspace: workspace
    } do
      {:ok, view, _html} = live(conn, ~p"/onboarding/storage/#{attempt.id}")

      assert has_element?(view, "button[phx-click=continue][disabled]")

      view |> element("#storage-hosted") |> render_click()
      assert has_element?(view, "#storage-hosted[aria-checked=true]")
      refute has_element?(view, "button[phx-click=continue][disabled]")
      assert Projects.get_onboarding_attempt(workspace, attempt.id).storage_mode == "hosted"
    end

    test "continue hands off to the confirmation step once hosted is chosen", %{
      conn: conn,
      attempt: attempt
    } do
      {:ok, view, _html} = live(conn, ~p"/onboarding/storage/#{attempt.id}")

      view |> element("#storage-hosted") |> render_click()
      view |> element("button[phx-click=continue]") |> render_click()

      assert_redirect(view, ~p"/onboarding/confirm/#{attempt.id}")
    end

    test "the setup action hands off to device setup", %{conn: conn, attempt: attempt} do
      {:ok, view, _html} = live(conn, ~p"/onboarding/storage/#{attempt.id}")

      view |> element("button[phx-click=setup_device]") |> render_click()
      assert_redirect(view, ~p"/onboarding/device-setup/#{attempt.id}")
    end
  end

  describe "storage step (device available via receipt)" do
    setup %{conn: conn} do
      ctx = setup_account(conn)
      attempt = ProjectsFixtures.attempt_with_repository(ctx.workspace)

      receipt = %DeviceStorageReceipt{
        token: "opaque",
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
        device_label: "Laptop"
      }

      {:ok, attempt} = Projects.record_device_receipt(ctx.workspace, attempt.id, receipt)
      Map.merge(ctx, %{attempt: attempt})
    end

    test "a recorded receipt makes device available without auto-selecting it (AC-26)", %{
      conn: conn,
      attempt: attempt
    } do
      {:ok, view, _html} = live(conn, ~p"/onboarding/storage/#{attempt.id}")

      # Device is selectable now, but nothing is selected by default (no silent default).
      refute has_element?(view, "#storage-device[aria-disabled=true]")
      refute has_element?(view, "#storage-device[aria-checked=true]")
      refute has_element?(view, "#storage-hosted[aria-checked=true]")
      assert has_element?(view, "button[phx-click=continue][disabled]")

      # It can now be explicitly selected.
      view |> element("#storage-device") |> render_click()
      assert has_element?(view, "#storage-device[aria-checked=true]")
      refute has_element?(view, "button[phx-click=continue][disabled]")
    end
  end

  describe "mount guards" do
    setup %{conn: conn}, do: setup_account(conn)

    test "sends an attempt without a selected repository back to the picker", %{
      conn: conn,
      workspace: workspace
    } do
      {:ok, attempt} = Projects.start_onboarding_attempt(workspace)

      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, ~p"/onboarding/storage/#{attempt.id}")

      assert to == "/onboarding/repository-access/#{attempt.id}"
    end

    test "routes an unknown attempt back to the catalog", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/projects"}}} =
               live(conn, ~p"/onboarding/storage/#{Ecto.UUID.generate()}")
    end

    test "never resolves another workspace's attempt", %{conn: conn} do
      foreign = ProjectsFixtures.workspace_fixture(AccountsFixtures.account_fixture())
      foreign_attempt = ProjectsFixtures.attempt_with_repository(foreign)

      assert {:error, {:live_redirect, %{to: "/projects"}}} =
               live(conn, ~p"/onboarding/storage/#{foreign_attempt.id}")
    end
  end

  test "requires an authenticated session", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} =
             live(conn, ~p"/onboarding/storage/#{Ecto.UUID.generate()}")
  end
end
