defmodule SddOrchestratorWeb.PairingRedemptionLiveTest do
  @moduledoc """
  specs/38-worker-initiated-pairing Task 4 proof.

  The pairing field is the redemption surface the workflow depends on. This
  proves a real code pairs the worker and lets the flow continue, that a refused
  code says one safe thing, and that the local worker stand-in no longer hides a
  redemption that genuinely failed.
  """
  use SddOrchestratorWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias SddOrchestrator.Devices

  alias SddOrchestrator.Devices.{
    DeviceStore.Local,
    Pairing,
    PairingIssuanceThrottle,
    WorkerDiscovery
  }

  @refused "Get a new one from the worker app"

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "sdd_pairing_live_#{System.unique_integer([:positive])}/store.dets"
      )

    on_exit(fn -> File.rm_rf!(Path.dirname(path)) end)
    start_supervised!({Local, path: path})
    PairingIssuanceThrottle.reset()

    {:ok, workspace} = Devices.establish_workspace()
    %{workspace: workspace}
  end

  defp without_stub(fun) do
    previous = Application.get_env(:sdd_orchestrator, :device_worker_stub)
    Application.put_env(:sdd_orchestrator, :device_worker_stub, false)

    try do
      fun.()
    after
      Application.put_env(:sdd_orchestrator, :device_worker_stub, previous)
    end
  end

  defp submit(view, code) do
    view |> form("#pairing-form", pairing: %{code: code}) |> render_submit()
  end

  # What the app itself does a moment after the code is bound: report the
  # versions only it knows and take its own credential.
  defp app_finishes(code) do
    policy = WorkerDiscovery.compatibility_policy()

    {:ok, %{worker: worker}} =
      Pairing.complete_pairing(code, %{
        os_family: policy.os_family,
        os_major: List.last(policy.os_majors),
        protocol_version: List.first(policy.protocol_versions),
        app_version: "0.0.0-test"
      })

    {:ok, _seen} = Pairing.mark_seen(worker)
    worker
  end

  describe "redeeming a real code (AC-04)" do
    test "binds the code, waits for the app, then lets the flow continue", %{
      conn: conn,
      workspace: workspace
    } do
      {:ok, %{code: code}} = Pairing.issue_unbound_code("test")

      without_stub(fn ->
        {:ok, view, html} = live(conn, ~p"/onboarding/local")
        assert html =~ ~s(data-worker-status="missing")

        submit(view, code)

        # The code was accepted, so the screen says so and stops asking for one.
        assert has_element?(view, "[data-worker-awaiting]")
        assert render(view) =~ "Finishing on your Mac"
        refute has_element?(view, "#pairing-form")

        # The app finishes on its own, and the screen catches up without a reload.
        app_finishes(code)
        render_click(view, "recheck")

        assert render(view) =~ ~s(data-worker-status="detected")
        refute has_element?(view, "[data-worker-awaiting]")
        assert has_element?(view, "[data-continue]")
      end)

      # It bound to this browser's own workspace, not some other one.
      assert [worker] = Pairing.active_workers(workspace.id)
      assert worker.device_workspace_id == workspace.id
    end

    test "surrounding whitespace from a paste is tolerated", %{conn: conn, workspace: workspace} do
      {:ok, %{code: code}} = Pairing.issue_unbound_code("test")

      without_stub(fn ->
        {:ok, view, _html} = live(conn, ~p"/onboarding/local")
        submit(view, "  #{code}\n")
        assert has_element?(view, "[data-worker-awaiting]")
      end)

      # Whitespace and all, the code bound to this workspace.
      app_finishes(code)
      assert [worker] = Pairing.active_workers(workspace.id)
      assert worker.device_workspace_id == workspace.id
    end
  end

  describe "a refused code" do
    test "says one safe thing and pairs nothing", %{conn: conn, workspace: workspace} do
      {:ok, %{code: code}} = Pairing.issue_unbound_code("test")
      :ok = Pairing.bind_pairing(code, Ecto.UUID.generate())

      without_stub(fn ->
        {:ok, view, _html} = live(conn, ~p"/onboarding/local")

        # Already redeemed, expired, and never issued all answer the same way.
        for refused <- [code, "#{Ecto.UUID.generate()}.nope", "not-a-code"] do
          assert submit(view, refused) =~ @refused
        end
      end)

      assert Pairing.active_workers(workspace.id) == []
    end

    test "an empty submission asks for a code without calling redemption", %{conn: conn} do
      without_stub(fn ->
        {:ok, view, _html} = live(conn, ~p"/onboarding/local")

        assert submit(view, "   ") =~ "Enter the pairing code shown in the worker app"
        refute render(view) =~ @refused
      end)
    end
  end

  describe "the local worker stand-in" do
    test "still drives the flow where it is enabled, since no app issues a code", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/onboarding/local")

      submit(view, "anything-at-all")

      assert render(view) =~ ~s(data-worker-status="detected")
    end

    test "a real code is bound for real before the stand-in finishes it", %{
      conn: conn,
      workspace: workspace
    } do
      {:ok, %{code: code}} = Pairing.issue_unbound_code("test")

      {:ok, view, _html} = live(conn, ~p"/onboarding/local")
      submit(view, code)

      assert render(view) =~ ~s(data-worker-status="detected")

      # The bind really happened and claimed the code for this workspace, which
      # the stand-in alone would never have done. Re-binding it elsewhere fails.
      assert {:error, :invalid_code} = Pairing.bind_pairing(code, Ecto.UUID.generate())
      assert :ok = Pairing.bind_pairing(code, workspace.id)
    end
  end

  describe "the field's copy" do
    test "no longer advertises a code format the product does not issue", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/onboarding/local")

      refute html =~ "4K7Q-2P9X"
      assert html =~ "Paste the code from the worker app"
    end
  end
end
