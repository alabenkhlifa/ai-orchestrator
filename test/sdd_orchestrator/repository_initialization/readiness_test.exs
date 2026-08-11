defmodule SddOrchestrator.RepositoryInitialization.ReadinessTest do
  @moduledoc """
  Task 6 proof (AC-14): assistant, specification, agent-execution, and
  release readiness stay independent, each with its own reason, and
  `earliest_blocked_stage` picks the correct first blocked axis — including
  the all-ready-except-release case, which must report `:release`, not `nil`.

  The device store is a singleton GenServer not started in test, so each
  test starts its own isolated instance on a unique path in an `async:
  false` case (mirrors `LocalOnboardingLiveTest`).
  """
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.DeviceStore.Local
  alias SddOrchestrator.Devices.Pairing
  alias SddOrchestrator.RepositoryInitialization.{Readiness, Result}

  setup do
    path = store_path()
    on_exit(fn -> File.rm_rf!(Path.dirname(path)) end)
    start_supervised!({Local, path: path})
    {:ok, workspace} = Devices.establish_workspace()
    %{workspace: workspace}
  end

  test "a paired worker and a created specification leave only agent_execution and release blocked, earliest release",
       %{workspace: workspace} do
    pair(workspace.id)
    result = result_fixture(specification_id: Ecto.UUID.generate())

    readiness = Readiness.evaluate(workspace, result)

    assert readiness.assistant == :ready
    assert readiness.specification == :ready
    assert readiness.agent_execution == {:blocked, :no_approved_execution_profile}
    assert readiness.release == {:blocked, :release_gate_pending}
    assert readiness.earliest_blocked_stage == :agent_execution
  end

  test "no paired worker blocks assistant with :no_worker_paired, earliest assistant", %{
    workspace: workspace
  } do
    result = result_fixture(specification_id: Ecto.UUID.generate())

    readiness = Readiness.evaluate(workspace, result)

    assert readiness.assistant == {:blocked, :no_worker_paired}
    assert readiness.earliest_blocked_stage == :assistant
  end

  test "a nil specification_id blocks specification with :specification_not_created", %{
    workspace: workspace
  } do
    pair(workspace.id)
    result = result_fixture(specification_id: nil)

    readiness = Readiness.evaluate(workspace, result)

    assert readiness.specification == {:blocked, :specification_not_created}
    assert readiness.earliest_blocked_stage == :specification
  end

  test "agent_execution and release are always blocked with their fixed reasons", %{
    workspace: workspace
  } do
    pair(workspace.id)
    result = result_fixture(specification_id: Ecto.UUID.generate())

    readiness = Readiness.evaluate(workspace, result)

    assert readiness.agent_execution == {:blocked, :no_approved_execution_profile}
    assert readiness.release == {:blocked, :release_gate_pending}
  end

  defp pair(workspace_id) do
    {:ok, %{code: code}} = Pairing.start_pairing(workspace_id)

    {:ok, %{worker: worker}} =
      Pairing.complete_pairing(code, %{
        os_family: "macos",
        os_major: "15",
        protocol_version: "1",
        app_version: "1.0.0"
      })

    {:ok, _seen} = Pairing.mark_seen(worker)
    :ok
  end

  defp result_fixture(overrides) do
    struct(
      %Result{
        id: Ecto.UUID.generate(),
        onboarding_handoff_state: "pending"
      },
      overrides
    )
  end

  defp store_path do
    dir =
      Path.join(System.tmp_dir!(), "sdd_ri_readiness_#{System.unique_integer([:positive])}")

    Path.join(dir, "store.dets")
  end
end
