defmodule SddOrchestrator.Devices.WorkerAvailabilityTest.Adapter do
  @moduledoc false
  @behaviour SddOrchestrator.RepositoryAssessments.RepositoryMetadataAdapter

  @commit "0123456789abcdef0123456789abcdef01234567"

  @impl true
  def prepare(request), do: respond(request)

  @impl true
  def revalidate(request), do: respond(request)

  defp respond(request) do
    send(self(), {:metadata_adapter_called, request.worker_ref})

    {:ok,
     %{
       repository_provider: request.repository_provider,
       repository_id: request.repository_id,
       root: request.selected_root,
       commit: @commit
     }}
  end
end

defmodule SddOrchestrator.Devices.WorkerAvailabilityTest do
  @moduledoc """
  Task 5 proof: one definition of an available worker.

  A worker is available when it is attached to the control plane right now, read
  from the Mac-scoped attachment registry. The assessment list offers a worker
  only on that answer and the action that follows authorizes on the same answer,
  so a list can no longer say a worker is available while the action refuses it
  inside the same minute.

  The development and test stand-in (`:device_worker_stub`) is on for the whole
  suite, so every test here turns it off for itself and proves the real
  definition. The last test proves the stand-in itself.
  """
  use SddOrchestratorWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias SddOrchestrator.Delivery.WorkerAttachment
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.DeviceStore.Local
  alias SddOrchestrator.Devices.Pairing
  alias SddOrchestrator.Devices.WorkerAvailabilityTest.Adapter
  alias SddOrchestrator.Devices.WorkerDiscovery
  alias SddOrchestrator.ProjectsFixtures
  alias SddOrchestrator.RepositoryAssessments
  alias SddOrchestrator.RepositoryAssessments.BindingStore
  alias SddOrchestratorWeb.RepositoryAssessmentLive

  @scanner_digest String.duplicate("a", 64)
  @disclosure_digest String.duplicate("b", 64)

  setup %{conn: conn} do
    store_path =
      Path.join(
        System.tmp_dir!(),
        "worker-availability-#{System.unique_integer([:positive])}/store.dets"
      )

    start_supervised!({Local, path: store_path})
    on_exit(fn -> File.rm_rf!(Path.dirname(store_path)) end)

    :ok = BindingStore.reset()

    previous_stub = Application.get_env(:sdd_orchestrator, :device_worker_stub)
    Application.put_env(:sdd_orchestrator, :device_worker_stub, false)
    on_exit(fn -> Application.put_env(:sdd_orchestrator, :device_worker_stub, previous_stub) end)

    %{conn: owner_conn, account: account} = register_and_log_in_account(%{conn: conn})
    workspace = ProjectsFixtures.workspace_fixture(account)
    hosted_project = ProjectsFixtures.registered_project(workspace, name: "Availability")

    {:ok, device_workspace} = Devices.establish_workspace()
    worker = paired_worker(device_workspace.id)

    %{
      account: account,
      device_workspace: device_workspace,
      hosted_project: hosted_project,
      owner_conn: owner_conn,
      worker: worker
    }
  end

  test "a paired worker with a fresh heartbeat and no attachment is neither listed nor authorized",
       context do
    assert context.worker.last_seen_at != nil
    assert WorkerAttachment.attached(context.device_workspace.id) == []

    refute Devices.worker_available?(context.worker)
    assert WorkerDiscovery.status([context.worker]) == :unavailable
    assert Devices.worker_status(context.device_workspace.id) == :unavailable

    assert {:error, :worker_unavailable} = prepare_binding(context)
    refute_received {:metadata_adapter_called, _worker_ref}
  end

  test "the same worker with an attachment registered is listed and authorized", context do
    attachment = attach(context.worker)

    assert Devices.worker_available?(context.worker)
    assert WorkerDiscovery.status([context.worker]) == :detected
    assert Devices.worker_status(context.device_workspace.id) == :detected

    assert {:ok, preparation} = prepare_binding(context)
    assert preparation.root == "."
    assert_received {:metadata_adapter_called, worker_ref}
    assert worker_ref == context.worker.id

    detach(attachment, context.device_workspace.id)
  end

  test "an attachment does not override a stale heartbeat", context do
    attachment = attach(context.worker)
    later = DateTime.add(DateTime.utc_now(), 2 * WorkerDiscovery.staleness_seconds(), :second)

    assert Devices.worker_available?(context.worker)
    assert WorkerDiscovery.status([context.worker], now: later) == :unavailable

    detach(attachment, context.device_workspace.id)
  end

  test "the empty list and the refused action say the one owned thing", context do
    attachment = attach(context.worker)
    path = ~p"/projects/#{context.hosted_project.id}/assessment"

    {:ok, _view, listed} = live(context.owner_conn, path)
    assert listed =~ context.worker.id
    refute listed =~ "data-no-workers"

    detach(attachment, context.device_workspace.id)

    {:ok, view, dropped} = live(context.owner_conn, path)
    refute dropped =~ context.worker.id
    assert view |> element("[data-no-workers]") |> render() =~ owned_message()

    refused =
      render_submit(view, "confirm_boundary", %{
        "assessment" => %{
          "confirmed" => "true",
          "selected_root" => ".",
          "worker_ref" => context.worker.id
        }
      })

    assert refused =~ owned_message()
    assert view |> element("[data-assessment-error]") |> render() =~ owned_message()
  end

  test "the stand-in treats a paired worker as attached, and only the stand-in does", context do
    refute Devices.worker_available?(context.worker)
    assert WorkerDiscovery.status([context.worker]) == :unavailable

    Application.put_env(:sdd_orchestrator, :device_worker_stub, true)

    assert Devices.worker_available?(context.worker)
    assert WorkerDiscovery.status([context.worker]) == :detected

    Application.put_env(:sdd_orchestrator, :device_worker_stub, false)

    refute Devices.worker_available?(context.worker)
    assert WorkerDiscovery.status([context.worker]) == :unavailable
  end

  # ---- helpers ----

  # The one owned wording both surfaces render, read from its owner rather than
  # copied here, so a reworded message cannot leave this proof asserting the old
  # sentence.
  defp owned_message, do: RepositoryAssessmentLive.worker_unavailable_message()

  defp prepare_binding(context) do
    RepositoryAssessments.prepare_binding(
      {:hosted, context.account.id},
      context.hosted_project.id,
      %{
        device_workspace_id: context.device_workspace.id,
        worker_ref: context.worker.id,
        selection_ref: "availability-#{System.unique_integer([:positive])}",
        selected_root: ".",
        scanner_contract_digest: @scanner_digest,
        disclosure_digest: @disclosure_digest,
        confirmed_disclosure_digest: @disclosure_digest
      },
      adapter: Adapter
    )
  end

  defp paired_worker(device_workspace_id) do
    {:ok, %{code: code}} = Pairing.start_pairing(device_workspace_id)

    {:ok, %{worker: worker}} =
      Pairing.complete_pairing(code, %{
        os_family: "macos",
        os_major: "26",
        app_version: "1.0.0",
        protocol_version: "1"
      })

    {:ok, worker} = Pairing.mark_seen(worker)
    worker
  end

  # A real registration, not an injected answer: the registry holds an entry only
  # while an attached process is alive, so the proof owns a process and ends it.
  defp attach(worker) do
    test = self()

    pid =
      spawn(fn ->
        {:ok, _owner} =
          WorkerAttachment.attach(worker.device_workspace_id, %{
            worker_id: worker.id,
            protocol_version: 1,
            capabilities: ["repository_selection"]
          })

        send(test, :attached)

        receive do
          :detach -> :ok
        end
      end)

    receive do
      :attached -> pid
    after
      1_000 -> flunk("the worker never attached")
    end
  end

  defp detach(pid, device_workspace_id) do
    reference = Process.monitor(pid)
    send(pid, :detach)

    receive do
      {:DOWN, ^reference, :process, ^pid, _reason} -> :ok
    after
      1_000 -> flunk("the attached process never stopped")
    end

    # The registry drops the entry when it sees the process go down, which is not
    # the same instant the process exits.
    wait_until(fn -> WorkerAttachment.attached(device_workspace_id) == [] end)
  end

  defp wait_until(check, attempts \\ 100) do
    cond do
      check.() -> :ok
      attempts == 0 -> flunk("the attachment never cleared")
      true -> Process.sleep(10) && wait_until(check, attempts - 1)
    end
  end
end
