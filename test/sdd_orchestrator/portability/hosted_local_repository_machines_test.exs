defmodule SddOrchestrator.Portability.HostedLocalRepositoryMachinesTest do
  @moduledoc """
  Task 2 proof for paired-machine selection.

  The binding boundary requires an explicitly selected worker, so this proof
  fixes what the owner is asked, what is decided for them, and what happens when
  the paired set changes between rendering the choice and submitting it.
  """

  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Accounts.DeviceWorkspace
  alias SddOrchestrator.Devices.{Pairing, WorkerDiscovery}
  alias SddOrchestrator.Portability.HostedLocalRepositoryMachines

  setup do
    device_workspace = %DeviceWorkspace{id: Ecto.UUID.generate()}
    %{device_workspace: device_workspace}
  end

  test "collapses to the single active worker without asking", context do
    worker = available_worker_fixture(context.device_workspace)

    assert {:ok, offer} = HostedLocalRepositoryMachines.offer(context.device_workspace)

    assert offer.selection == :single
    assert offer.preselected_worker_id == worker.id
    assert [%{worker_id: worker_id, available?: true}] = offer.machines
    assert worker_id == worker.id

    assert {:ok, ^worker_id} =
             HostedLocalRepositoryMachines.confirm(context.device_workspace, nil)
  end

  test "asks for an explicit choice when more than one machine is paired", context do
    first = available_worker_fixture(context.device_workspace)
    second = available_worker_fixture(context.device_workspace)

    assert {:ok, offer} = HostedLocalRepositoryMachines.offer(context.device_workspace)

    assert offer.selection == :explicit
    assert offer.preselected_worker_id == nil

    assert offer.machines |> Enum.map(& &1.worker_id) |> Enum.sort() ==
             Enum.sort([first.id, second.id])

    assert {:ok, id} =
             HostedLocalRepositoryMachines.confirm(context.device_workspace, second.id)

    assert id == second.id
  end

  test "never substitutes a machine paired between listing and submit", context do
    seen = available_worker_fixture(context.device_workspace)

    assert {:ok, %{selection: :single, preselected_worker_id: preselected}} =
             HostedLocalRepositoryMachines.offer(context.device_workspace)

    assert preselected == seen.id

    unseen = available_worker_fixture(context.device_workspace)

    assert {:error, :selection_required} =
             HostedLocalRepositoryMachines.confirm(context.device_workspace, nil)

    assert {:ok, id} = HostedLocalRepositoryMachines.confirm(context.device_workspace, seen.id)
    assert id == seen.id
    refute id == unseen.id
  end

  test "excludes revoked machines from selection and from confirmation", context do
    kept = available_worker_fixture(context.device_workspace)
    revoked_source = available_worker_fixture(context.device_workspace)

    assert {:ok, %{selection: :explicit}} =
             HostedLocalRepositoryMachines.offer(context.device_workspace)

    assert {:ok, revoked} = Pairing.revoke_worker(revoked_source)

    assert {:ok, offer} = HostedLocalRepositoryMachines.offer(context.device_workspace)
    assert offer.selection == :single
    assert offer.preselected_worker_id == kept.id
    assert Enum.map(offer.machines, & &1.worker_id) == [kept.id]

    assert {:error, :unauthorized_worker} =
             HostedLocalRepositoryMachines.confirm(context.device_workspace, revoked.id)

    assert {:error, :unauthorized_worker} =
             HostedLocalRepositoryMachines.confirm(
               context.device_workspace,
               Ecto.UUID.generate()
             )
  end

  test "reports a machine that is paired but not currently reachable", context do
    unreachable = paired_worker_fixture(context.device_workspace)

    assert {:ok, offer} = HostedLocalRepositoryMachines.offer(context.device_workspace)
    assert [%{worker_id: worker_id, available?: false}] = offer.machines
    assert worker_id == unreachable.id

    reachable = available_worker_fixture(context.device_workspace)

    stale =
      DateTime.utc_now()
      |> DateTime.add(WorkerDiscovery.staleness_seconds() + 1, :second)

    assert {:ok, stale_offer} =
             HostedLocalRepositoryMachines.offer(context.device_workspace, now: stale)

    assert Enum.all?(stale_offer.machines, &(&1.available? == false))
    assert reachable.id in Enum.map(stale_offer.machines, & &1.worker_id)
  end

  test "exposes only an opaque worker id and reachability", context do
    _worker = available_worker_fixture(context.device_workspace)

    assert {:ok, offer} = HostedLocalRepositoryMachines.offer(context.device_workspace)

    for machine <- offer.machines do
      assert machine |> Map.keys() |> Enum.sort() == [:available?, :worker_id]
    end

    rendered = inspect(offer)

    for forbidden <- ~w(macos os_family os_major app_version protocol_version credential
                        last_seen_at device_workspace_id) do
      refute rendered =~ forbidden
    end
  end

  test "reports no paired worker distinctly and guides without a terminal command",
       context do
    assert {:error, :no_worker_paired} =
             HostedLocalRepositoryMachines.offer(context.device_workspace)

    assert {:error, :no_worker_paired} =
             HostedLocalRepositoryMachines.confirm(context.device_workspace, nil)

    assert {:error, :no_worker_paired} = HostedLocalRepositoryMachines.offer(nil)
    assert {:error, :no_worker_paired} = HostedLocalRepositoryMachines.confirm(nil, nil)

    guidance = HostedLocalRepositoryMachines.guidance()
    assert Enum.map(guidance.steps, & &1.action) == [:download, :pair]

    copy =
      [guidance.headline | Enum.flat_map(guidance.steps, &[&1.title, &1.detail])]
      |> Enum.join(" ")
      |> String.downcase()

    terminal_markers = [
      "terminal",
      "command",
      "shell",
      "sudo",
      "brew ",
      "curl ",
      "npm ",
      "git ",
      "chmod",
      "$ ",
      ">_"
    ]

    for marker <- terminal_markers do
      refute String.contains?(copy, marker)
    end
  end

  defp available_worker_fixture(device_workspace) do
    worker = paired_worker_fixture(device_workspace)
    {:ok, worker} = Pairing.mark_seen(worker)
    worker
  end

  defp paired_worker_fixture(device_workspace) do
    {:ok, %{code: code}} = Pairing.start_pairing(device_workspace.id)

    {:ok, %{worker: worker}} =
      Pairing.complete_pairing(code, %{
        os_family: "macos",
        os_major: "26",
        app_version: "1.0.0",
        protocol_version: "1"
      })

    worker
  end
end
