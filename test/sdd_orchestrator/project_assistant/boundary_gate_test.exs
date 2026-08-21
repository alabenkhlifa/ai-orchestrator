defmodule SddOrchestrator.ProjectAssistant.BoundaryGateTest do
  @moduledoc """
  specs/12-project-assistant Task 2 focused proof for
  `SddOrchestrator.ProjectAssistant.BoundaryGate`: AC-04 (no fallback, safe
  setup/status guidance), AC-05 (no read tool or model call before a
  matching confirmation), and AC-06 (an unchanged boundary lets a later
  question proceed automatically).
  """
  use SddOrchestrator.DataCase, async: false

  import SddOrchestrator.AIRuntimeFixtures

  alias SddOrchestrator.AIRuntime.AIRuntimeSession
  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.DeviceStore.Local
  alias SddOrchestrator.Devices.Pairing
  alias SddOrchestrator.Participation.ProjectParticipant
  alias SddOrchestrator.ProjectAssistant.{AssistantBoundaryConfirmation, BoundaryGate}

  @now ~U[2026-08-03 12:00:00Z]

  describe "hosted authority" do
    setup do
      DeliveryFixtures.delivery_project_fixture()
    end

    test "no eligible connection: setup_needed, and confirmation is refused rather than faked",
         %{project: project, workspace: workspace, owner_actor: owner_actor} do
      assert {:ok, %{availability: %{state: :setup_needed}, confirmation_required: true}} =
               BoundaryGate.status(workspace, project.id, owner_actor, nil, now: @now)

      assert {:error, :setup_needed} =
               BoundaryGate.confirm(workspace, project.id, owner_actor, nil, now: @now)

      assert {:error, :setup_needed} =
               BoundaryGate.authorize_turn(workspace, project.id, owner_actor, nil, now: @now)

      assert Repo.aggregate(AssistantBoundaryConfirmation, :count) == 0
    end

    test "no read tool or model call runs before a matching confirmation, then it does",
         %{project: project, workspace: workspace, owner_actor: owner_actor, account: account} do
      runtime_session_context_fixture(%{account: account})

      assert {:error, :confirmation_required} =
               BoundaryGate.authorize_turn(workspace, project.id, owner_actor, account, now: @now)

      assert {:ok, confirmation} =
               BoundaryGate.confirm(workspace, project.id, owner_actor, account, now: @now)

      assert confirmation.account_id == account.id
      assert Repo.aggregate(AssistantBoundaryConfirmation, :count) == 1

      assert :ok =
               BoundaryGate.authorize_turn(workspace, project.id, owner_actor, account, now: @now)

      # Unchanged boundary: a second question proceeds without reconfirmation (AC-06).
      assert :ok =
               BoundaryGate.authorize_turn(workspace, project.id, owner_actor, account, now: @now)
    end

    test "reconfirming replaces the stored digest in place rather than appending a row",
         %{project: project, workspace: workspace, owner_actor: owner_actor, account: account} do
      runtime_session_context_fixture(%{account: account})

      assert {:ok, first} =
               BoundaryGate.confirm(workspace, project.id, owner_actor, account, now: @now)

      assert {:ok, second} =
               BoundaryGate.confirm(workspace, project.id, owner_actor, account, now: @now)

      assert first.id == second.id
      assert Repo.aggregate(AssistantBoundaryConfirmation, :count) == 1
    end

    test "a removed participant is refused status, confirm, and the pre-tool gate identically",
         %{
           project: project,
           workspace: workspace,
           participant_actor: participant_actor,
           identity: identity
         } do
      participant =
        Repo.get_by!(ProjectParticipant,
          project_id: project.id,
          hosted_identity_id: identity.hosted_identity.id
        )

      participant
      |> ProjectParticipant.departure_changeset(%{departure_reason: "removed"})
      |> Repo.update!()

      assert {:error, :unauthorized} =
               BoundaryGate.status(workspace, project.id, participant_actor, nil, now: @now)

      assert {:error, :unauthorized} =
               BoundaryGate.confirm(workspace, project.id, participant_actor, nil, now: @now)

      assert {:error, :unauthorized} =
               BoundaryGate.authorize_turn(workspace, project.id, participant_actor, nil,
                 now: @now
               )
    end
  end

  describe "device authority: material boundary change" do
    setup do
      path = store_path()
      on_exit(fn -> File.rm_rf!(Path.dirname(path)) end)
      start_supervised!({Local, path: path})

      {:ok, workspace} = Devices.establish_workspace()

      {:ok, project} =
        Devices.register_project(%{
          name: "Device assistant project",
          repository_fingerprint:
            "device-assistant-fingerprint-#{System.unique_integer([:positive])}",
          status: "connected",
          idempotency_key: Ecto.UUID.generate()
        })

      %{account: account} = runtime_session_context_fixture(%{now: @now})

      %{workspace: workspace, project: project, account: account}
    end

    test "pairing a repository worker after confirmation invalidates it; a fresh confirmation restores the gate",
         %{workspace: workspace, project: project, account: account} do
      assert {:error, :confirmation_required} =
               BoundaryGate.authorize_turn(workspace, project.id, %{}, account, now: @now)

      assert {:ok, confirmation1} =
               BoundaryGate.confirm(workspace, project.id, %{}, account, now: @now)

      assert :ok = BoundaryGate.authorize_turn(workspace, project.id, %{}, account, now: @now)

      # Unchanged boundary: proceeds again without reconfirmation.
      assert :ok = BoundaryGate.authorize_turn(workspace, project.id, %{}, account, now: @now)

      # Material change: a repository worker becomes reachable for this device workspace.
      reachable_worker(workspace.id)

      assert {:error, :confirmation_required} =
               BoundaryGate.authorize_turn(workspace, project.id, %{}, account, now: @now)

      assert {:ok, confirmation2} =
               BoundaryGate.confirm(workspace, project.id, %{}, account, now: @now)

      refute confirmation2.boundary_digest == confirmation1.boundary_digest
      assert confirmation2.id == confirmation1.id

      assert :ok = BoundaryGate.authorize_turn(workspace, project.id, %{}, account, now: @now)
    end

    test "a stale device workspace is refused identically to a wrong project", %{
      project: project,
      workspace: workspace,
      account: account
    } do
      other_workspace = %SddOrchestrator.Accounts.DeviceWorkspace{id: Ecto.UUID.generate()}

      assert {:error, :unauthorized} =
               BoundaryGate.authorize_turn(other_workspace, project.id, %{}, account, now: @now)

      assert {:error, :unauthorized} =
               BoundaryGate.authorize_turn(workspace, Ecto.UUID.generate(), %{}, account,
                 now: @now
               )
    end
  end

  describe "no fallback provider ever runs" do
    test "temporarily limited never pins a session and never invalidates an existing confirmation" do
      %{project: project, workspace: workspace, owner_actor: owner_actor, account: account} =
        DeliveryFixtures.delivery_project_fixture()

      context = runtime_session_context_fixture(%{account: account, now: @now})

      assert {:ok, confirmation} =
               BoundaryGate.confirm(workspace, project.id, owner_actor, account, now: @now)

      assert :ok =
               BoundaryGate.authorize_turn(workspace, project.id, owner_actor, account, now: @now)

      replace_quota(context)

      assert {:error, :temporarily_limited} =
               BoundaryGate.authorize_turn(workspace, project.id, owner_actor, account, now: @now)

      # The confirmation itself was not invalidated by a transient pause.
      assert {:ok, %{confirmation: ^confirmation}} =
               BoundaryGate.status(workspace, project.id, owner_actor, account, now: @now)

      assert Repo.aggregate(AIRuntimeSession, :count) == 1
    end
  end

  defp replace_quota(context) do
    bucket =
      quota_bucket(%{
        primary_window: %{
          used_percent: 100,
          resets_at: ~U[2026-08-03 13:00:00Z],
          duration_minutes: 300,
          unknown_fields: []
        },
        paid_continuation: "available",
        unknown_fields: [
          "secondary_window",
          "spend_control",
          "spend_control_reached",
          "limit_reached_reason"
        ]
      })

    result = quota_adapter_result(%{retrieved_at: @now, buckets: [bucket]})

    assert {:ok, _quota} =
             SddOrchestrator.AIRuntime.Quotas.refresh(context.account, context.connection.id,
               adapter: SddOrchestrator.QuotaAdapterDouble,
               adapter_result: {:ok, result},
               now: @now,
               ttl_seconds: 300
             )
  end

  defp store_path do
    Path.join(
      System.tmp_dir!(),
      "boundary_gate_device_store_#{System.unique_integer([:positive])}/store.dets"
    )
  end

  # A `WorkerDiscovery`-compatible, currently reachable worker — deliberately
  # not `personal_ai_worker_fixture/1`, whose default `protocol_version`
  # ("personal-ai/1") is the AI-runtime capability protocol, not the
  # repository-worker compatibility policy this helper needs to satisfy.
  defp reachable_worker(device_workspace_id) do
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
end
