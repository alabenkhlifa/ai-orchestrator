defmodule SddOrchestrator.Devices.WorkerLivenessRefresherTest do
  @moduledoc """
  Task 11 proof: one refresher pass stamps `last_seen_at` for exactly the workers
  currently attached to this node's worker registry, so a genuinely connected
  worker keeps reading as reachable without any worker-initiated call.

  Slice 39 Task 6 proof (AC-06, AC-09): a worker attached for its Mac alone is
  refreshed with no project opened and no worker self-report, a worker attached
  for both its Mac and a project is stamped once, and an attachment that goes
  away reads as unavailable once the staleness window passes while its paired
  worker stays visible rather than looking deleted.
  """
  # Not `async: true`: `refresh/0` enumerates the whole shared
  # `Delivery.CommandTransport.Channel` and `Delivery.WorkerAttachment`
  # registries, so a concurrently registered worker from another test would land
  # in this test's own pass.
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Delivery.CommandTransport.Channel, as: WorkerTransport
  alias SddOrchestrator.Delivery.WorkerAttachment
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.LocalWorker
  alias SddOrchestrator.Devices.Pairing
  alias SddOrchestrator.Devices.WorkerDiscovery
  alias SddOrchestrator.Devices.WorkerLivenessRefresher
  alias SddOrchestrator.Repo

  defp pair(workspace_id, worker_attrs \\ %{}) do
    {:ok, %{code: code}} = Pairing.start_pairing(workspace_id)

    {:ok, %{worker: worker}} =
      Pairing.complete_pairing(
        code,
        Map.merge(%{os_family: "macos", os_major: "26", protocol_version: "1"}, worker_attrs)
      )

    worker
  end

  # Registers the calling test process in the project-keyed transport registry,
  # the same way `WorkerChannel.join/3` registers a real authenticated connection.
  defp attach_for_project(worker) do
    {:ok, _pid} =
      WorkerTransport.attach(Ecto.UUID.generate(), %{
        worker_id: worker.id,
        protocol_version: 1,
        capabilities: ["run.start"]
      })

    worker
  end

  # Registers the calling test process in the Mac-keyed attachment registry, the
  # same way `WorkerWorkspaceChannel.join/3` registers a worker paired from the
  # app's menu bar with no project opened.
  defp attach_for_mac(worker) do
    {:ok, _pid} =
      WorkerAttachment.attach(worker.device_workspace_id, %{
        worker_id: worker.id,
        protocol_version: 1,
        capabilities: ["run.start"]
      })

    worker
  end

  defp detach_from_mac(worker) do
    :ok = Registry.unregister(WorkerAttachment.registry(), worker.device_workspace_id)
    worker
  end

  # Ages `last_seen_at` past the staleness window instead of sleeping through it.
  defp age_past_staleness(worker) do
    stale_at =
      DateTime.utc_now()
      |> DateTime.add(-(WorkerDiscovery.staleness_seconds() + 1), :second)
      |> DateTime.truncate(:second)

    LocalWorker
    |> Repo.get!(worker.id)
    |> Ecto.Changeset.change(last_seen_at: stale_at)
    |> Repo.update!()
  end

  defp last_seen(worker), do: Repo.get!(LocalWorker, worker.id).last_seen_at

  test "one pass marks every attached worker seen" do
    workspace = Ecto.UUID.generate()
    first = workspace |> pair() |> attach_for_project()
    second = workspace |> pair() |> attach_for_project()

    assert is_nil(last_seen(first))
    assert is_nil(last_seen(second))

    assert WorkerLivenessRefresher.refresh() == 2

    refute is_nil(last_seen(first))
    refute is_nil(last_seen(second))
  end

  test "a paired but unattached worker is left untouched" do
    workspace = Ecto.UUID.generate()
    attached = workspace |> pair() |> attach_for_project()
    unattached = pair(workspace)

    assert WorkerLivenessRefresher.refresh() == 1

    refute is_nil(last_seen(attached))
    assert is_nil(last_seen(unattached))
  end

  test "a revoked attached worker is skipped without failing the pass" do
    workspace = Ecto.UUID.generate()
    revoked = workspace |> pair() |> attach_for_project()
    {:ok, _revoked} = Pairing.revoke_worker(revoked)
    active = workspace |> pair() |> attach_for_project()

    assert WorkerLivenessRefresher.refresh() == 1

    assert is_nil(last_seen(revoked))
    refute is_nil(last_seen(active))
  end

  test "an attached registration whose worker row is gone does not fail the pass" do
    workspace = Ecto.UUID.generate()
    missing = workspace |> pair() |> attach_for_project()
    active = workspace |> pair() |> attach_for_project()
    Repo.delete!(Repo.get!(LocalWorker, missing.id))

    assert WorkerLivenessRefresher.refresh() == 1
    refute is_nil(last_seen(active))
  end

  test "a pass moves discovery from :unavailable to :detected with no worker-initiated call" do
    workspace = Ecto.UUID.generate()
    _worker = workspace |> pair() |> attach_for_project()

    assert Devices.worker_status(workspace) == :unavailable

    assert WorkerLivenessRefresher.refresh() == 1

    assert Devices.worker_status(workspace) == :detected
  end

  test "one pass marks a worker attached only for its Mac seen" do
    workspace = Ecto.UUID.generate()
    worker = workspace |> pair() |> attach_for_mac()

    assert is_nil(last_seen(worker))
    assert Devices.worker_status(workspace) == :unavailable

    assert WorkerLivenessRefresher.refresh() == 1

    refute is_nil(last_seen(worker))
  end

  test "a worker attached for both its Mac and a project is marked seen once" do
    workspace = Ecto.UUID.generate()
    worker = workspace |> pair() |> attach_for_mac() |> attach_for_project()

    # The returned count, not the timestamp, is what a second stamp would show in.
    assert WorkerLivenessRefresher.refresh() == 1

    refute is_nil(last_seen(worker))
  end

  test "a revoked Mac-attached worker is skipped without failing the pass" do
    workspace = Ecto.UUID.generate()
    revoked = workspace |> pair() |> attach_for_mac()
    {:ok, _revoked} = Pairing.revoke_worker(revoked)
    active = workspace |> pair() |> attach_for_mac()

    assert WorkerLivenessRefresher.refresh() == 1

    assert is_nil(last_seen(revoked))
    refute is_nil(last_seen(active))
  end

  test "a pass moves a Mac-attached worker to :detected with no project opened" do
    workspace = Ecto.UUID.generate()
    _worker = workspace |> pair() |> attach_for_mac()

    assert Devices.worker_status(workspace) == :unavailable

    # Nothing here calls `Pairing.mark_seen/1`: only the refresher stamps it.
    assert WorkerLivenessRefresher.refresh() == 1

    assert Devices.worker_status(workspace) == :detected
  end

  test "a gone Mac attachment reads unavailable once the staleness window passes" do
    workspace = Ecto.UUID.generate()
    worker = workspace |> pair() |> attach_for_mac()

    assert WorkerLivenessRefresher.refresh() == 1
    assert Devices.worker_status(workspace) == :detected

    worker |> detach_from_mac() |> age_past_staleness()

    assert WorkerLivenessRefresher.refresh() == 0
    assert Devices.worker_status(workspace) == :unavailable

    # AC-09's second half at this layer: the worker stays paired and active, so the
    # workspace reads unavailable rather than `:missing`, which is the status that
    # keeps its projects visible with a connection state instead of deleted.
    assert [%LocalWorker{id: id, state: "active"}] = Pairing.active_workers(workspace)
    assert id == worker.id
  end

  test "refreshing with nothing attached is a no-op" do
    assert WorkerLivenessRefresher.refresh() == 0
  end

  test "the refresh interval stays well inside the staleness window" do
    interval_seconds = div(WorkerLivenessRefresher.default_interval(), 1000)

    assert interval_seconds > 0
    assert interval_seconds < WorkerDiscovery.staleness_seconds()
  end
end
