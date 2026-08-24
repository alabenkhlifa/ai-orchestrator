defmodule SddOrchestrator.Devices.WorkerLivenessRefresherTest do
  @moduledoc """
  Task 11 proof: one refresher pass stamps `last_seen_at` for exactly the workers
  currently attached to this node's worker registry, so a genuinely connected
  worker keeps reading as reachable without any worker-initiated call.
  """
  # Not `async: true`: `refresh/0` enumerates the whole shared
  # `Delivery.CommandTransport.Channel` registry, so a concurrently registered
  # worker from another test would land in this test's own pass.
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Delivery.CommandTransport.Channel, as: WorkerTransport
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

  # Registers the calling test process as the attached worker for a project, the
  # same way `WorkerChannel.join/3` registers a real authenticated connection.
  defp attach(worker) do
    {:ok, _pid} =
      WorkerTransport.attach(Ecto.UUID.generate(), %{
        worker_id: worker.id,
        protocol_version: 1,
        capabilities: ["run.start"]
      })

    worker
  end

  defp last_seen(worker), do: Repo.get!(LocalWorker, worker.id).last_seen_at

  test "one pass marks every attached worker seen" do
    workspace = Ecto.UUID.generate()
    first = workspace |> pair() |> attach()
    second = workspace |> pair() |> attach()

    assert is_nil(last_seen(first))
    assert is_nil(last_seen(second))

    assert WorkerLivenessRefresher.refresh() == 2

    refute is_nil(last_seen(first))
    refute is_nil(last_seen(second))
  end

  test "a paired but unattached worker is left untouched" do
    workspace = Ecto.UUID.generate()
    attached = workspace |> pair() |> attach()
    unattached = pair(workspace)

    assert WorkerLivenessRefresher.refresh() == 1

    refute is_nil(last_seen(attached))
    assert is_nil(last_seen(unattached))
  end

  test "a revoked attached worker is skipped without failing the pass" do
    workspace = Ecto.UUID.generate()
    revoked = workspace |> pair() |> attach()
    {:ok, _revoked} = Pairing.revoke_worker(revoked)
    active = workspace |> pair() |> attach()

    assert WorkerLivenessRefresher.refresh() == 1

    assert is_nil(last_seen(revoked))
    refute is_nil(last_seen(active))
  end

  test "an attached registration whose worker row is gone does not fail the pass" do
    workspace = Ecto.UUID.generate()
    missing = workspace |> pair() |> attach()
    active = workspace |> pair() |> attach()
    Repo.delete!(Repo.get!(LocalWorker, missing.id))

    assert WorkerLivenessRefresher.refresh() == 1
    refute is_nil(last_seen(active))
  end

  test "a pass moves discovery from :unavailable to :detected with no worker-initiated call" do
    workspace = Ecto.UUID.generate()
    _worker = workspace |> pair() |> attach()

    assert Devices.worker_status(workspace) == :unavailable

    assert WorkerLivenessRefresher.refresh() == 1

    assert Devices.worker_status(workspace) == :detected
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
