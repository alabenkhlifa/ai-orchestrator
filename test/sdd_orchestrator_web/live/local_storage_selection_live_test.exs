defmodule SddOrchestratorWeb.LocalStorageSelectionLiveTest do
  @moduledoc """
  Proof for the shared storage-selection step on the accountless local flow.

  It covers both modes staying visible with the approved copy, hosted storage
  shown unavailable with a non-selecting sign-in action while no hosted identity
  is disclosed (AC-02), the sign-in handoff binding a one-time return to this same
  step and a completed sign-in refreshing hosted availability without selecting it
  (AC-14), device availability refreshing from a recorded receipt without
  auto-selection (AC-03), and that no mode is silently selected on any path.

  The device store is a singleton GenServer not started in test, so each test uses
  its own isolated instance on a unique path in an `async: false` case.
  """
  use SddOrchestratorWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.DeviceStore.Local
  alias SddOrchestrator.HostedAccess.SessionCookie
  alias SddOrchestrator.HostedAccessFixtures
  alias SddOrchestrator.Projects
  alias SddOrchestrator.ProjectsFixtures

  setup do
    path = store_path()
    on_exit(fn -> File.rm_rf!(Path.dirname(path)) end)
    start_supervised!({Local, path: path})
    {:ok, device} = Devices.establish_workspace()
    attempt = ProjectsFixtures.device_attempt_with_repository(device)
    %{device: device, attempt: attempt}
  end

  describe "accountless storage step" do
    test "shows both modes with the approved copy and hosted unavailable with a sign-in action (AC-01, AC-02)",
         %{conn: conn, attempt: attempt} do
      {:ok, view, html} = live(conn, ~p"/onboarding/local/storage/#{attempt.id}")

      assert html =~ ~s(data-screen="storage-selection")
      assert html =~ "Where should your project work be saved?"

      assert html =~
               "Your project work includes specifications, tasks, agent runs, and generated files. Your linked repository stays where it is."

      assert html =~ "In my SDD Orchestrator account"
      assert html =~ "On this device"

      # Hosted stays visible but unavailable, explaining sign-in with a non-selecting action.
      assert has_element?(view, "#storage-hosted[aria-disabled=true]")
      assert html =~ "needs you to sign in"
      assert has_element?(view, "button[phx-click=setup_hosted]")

      # Device is also unavailable until setup, and keeps its own setup action.
      assert has_element?(view, "#storage-device[aria-disabled=true]")
      assert has_element?(view, "button[phx-click=setup_device]")

      # Continuation is blocked with no silent default.
      assert has_element?(view, "button[phx-click=continue][disabled]")
    end

    test "discloses no hosted identity before sign-in (AC-14 account-neutral)", %{
      conn: conn,
      attempt: attempt
    } do
      {:ok, _view, html} = live(conn, ~p"/onboarding/local/storage/#{attempt.id}")

      refute html =~ "@"
      refute html =~ "Sign out"
    end

    test "trying to select the unavailable hosted mode selects nothing", %{
      conn: conn,
      device: device,
      attempt: attempt
    } do
      {:ok, view, _html} = live(conn, ~p"/onboarding/local/storage/#{attempt.id}")

      view |> element("#storage-hosted") |> render_click()

      refute has_element?(view, "#storage-hosted[aria-checked=true]")
      assert is_nil(Projects.get_device_onboarding_attempt(device, attempt.id).storage_mode)
    end

    test "the sign-in action hands off to hosted access with a return to this same step (AC-14)",
         %{
           conn: conn,
           attempt: attempt
         } do
      {:ok, view, _html} = live(conn, ~p"/onboarding/local/storage/#{attempt.id}")

      view |> element("button[phx-click=setup_hosted]") |> render_click()

      expected =
        "/hosted/access?" <>
          URI.encode_query(return_to: "/onboarding/local/storage/#{attempt.id}")

      assert_redirect(view, expected)
    end

    test "the device setup action hands off to the local flow (AC-03)", %{
      conn: conn,
      attempt: attempt
    } do
      {:ok, view, _html} = live(conn, ~p"/onboarding/local/storage/#{attempt.id}")

      view |> element("button[phx-click=setup_device]") |> render_click()
      assert_redirect(view, ~p"/onboarding/local")
    end
  end

  describe "hosted sign-in return" do
    test "a completed sign-in refreshes hosted availability without selecting it (AC-14)", %{
      conn: conn,
      device: device,
      attempt: attempt
    } do
      hosted =
        HostedAccessFixtures.verified_hosted_session_fixture(email: "returner@example.com")

      conn =
        init_test_session(conn, %{
          SessionCookie.session_key() => hosted.session_cookie.value
        })

      {:ok, view, _html} = live(conn, ~p"/onboarding/local/storage/#{attempt.id}")

      # Hosted is now available, but nothing is selected (no silent default).
      refute has_element?(view, "#storage-hosted[aria-disabled=true]")
      refute has_element?(view, "#storage-hosted[aria-checked=true]")
      assert has_element?(view, "button[phx-click=continue][disabled]")

      # The proven hosted workspace was recorded as the prerequisite, and no
      # project was created.
      recorded = Projects.get_device_onboarding_attempt(device, attempt.id)
      assert recorded.hosted_prerequisite_workspace_id == hosted.personal_workspace.id
      assert is_nil(recorded.storage_mode)

      # It can now be explicitly selected.
      view |> element("#storage-hosted") |> render_click()
      assert has_element?(view, "#storage-hosted[aria-checked=true]")
      refute has_element?(view, "button[phx-click=continue][disabled]")
    end
  end

  describe "device availability via receipt" do
    test "a recorded receipt makes device available without auto-selecting it (AC-03)", %{
      conn: conn,
      device: device,
      attempt: attempt
    } do
      receipt = ProjectsFixtures.device_receipt(attempt)
      {:ok, attempt} = Projects.record_device_receipt(device, attempt.id, receipt)

      {:ok, view, _html} = live(conn, ~p"/onboarding/local/storage/#{attempt.id}")

      refute has_element?(view, "#storage-device[aria-disabled=true]")
      refute has_element?(view, "#storage-device[aria-checked=true]")
      assert has_element?(view, "button[phx-click=continue][disabled]")

      view |> element("#storage-device") |> render_click()
      assert has_element?(view, "#storage-device[aria-checked=true]")
      refute has_element?(view, "button[phx-click=continue][disabled]")
    end
  end

  describe "mount guards" do
    test "routes an unknown attempt back to the local flow", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/onboarding/local"}}} =
               live(conn, ~p"/onboarding/local/storage/#{Ecto.UUID.generate()}")
    end

    test "never resolves another device's attempt", %{conn: conn} do
      other = ProjectsFixtures.device_workspace_fixture()
      foreign = ProjectsFixtures.device_attempt_with_repository(other)

      assert {:error, {:live_redirect, %{to: "/onboarding/local"}}} =
               live(conn, ~p"/onboarding/local/storage/#{foreign.id}")
    end
  end

  defp store_path do
    dir =
      Path.join(System.tmp_dir!(), "sdd_local_storage_#{System.unique_integer([:positive])}")

    Path.join(dir, "store.dets")
  end
end
