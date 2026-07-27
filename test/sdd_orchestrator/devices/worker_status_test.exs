defmodule SddOrchestrator.Devices.WorkerStatusTest do
  @moduledoc """
  Task 2 proof (integration): `Pairing.active_workers/1` scopes discovery to one
  workspace's non-revoked workers, and `Devices.worker_status/1` maps them through
  the compatibility and reachability policy to a discovery status.
  """
  use SddOrchestrator.DataCase, async: true

  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.Pairing

  defp pair(workspace_id, worker_attrs \\ %{}) do
    {:ok, %{code: code}} = Pairing.start_pairing(workspace_id)

    {:ok, %{worker: worker}} =
      Pairing.complete_pairing(
        code,
        Map.merge(
          %{os_family: "macos", os_major: "15", protocol_version: "1"},
          worker_attrs
        )
      )

    worker
  end

  defp seen_now(worker) do
    {:ok, seen} = Pairing.mark_seen(worker)
    seen
  end

  test "active_workers/1 lists only this workspace's active workers" do
    ws = Ecto.UUID.generate()
    other = Ecto.UUID.generate()

    kept = pair(ws)
    revoked = pair(ws)
    {:ok, _} = Pairing.revoke_worker(revoked)
    _foreign = pair(other)

    ids = ws |> Pairing.active_workers() |> Enum.map(& &1.id)
    assert ids == [kept.id]
  end

  test "worker_status/1 is :missing with no paired worker" do
    assert Devices.worker_status(Ecto.UUID.generate()) == :missing
  end

  test "worker_status/1 is :detected for a compatible worker seen just now" do
    ws = Ecto.UUID.generate()
    ws |> pair() |> seen_now()
    assert Devices.worker_status(ws) == :detected
  end

  test "worker_status/1 is :unavailable for a compatible worker never seen" do
    ws = Ecto.UUID.generate()
    _worker = pair(ws)
    assert Devices.worker_status(ws) == :unavailable
  end

  test "worker_status/1 is :incompatible for an unsupported worker" do
    ws = Ecto.UUID.generate()
    ws |> pair(%{os_major: "13"}) |> seen_now()
    assert Devices.worker_status(ws) == :incompatible
  end

  test "worker_status/1 ignores a revoked worker" do
    ws = Ecto.UUID.generate()
    worker = pair(ws) |> seen_now()
    assert Devices.worker_status(ws) == :detected

    {:ok, _} = Pairing.revoke_worker(worker)
    assert Devices.worker_status(ws) == :missing
  end
end
