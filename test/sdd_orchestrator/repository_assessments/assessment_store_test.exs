defmodule SddOrchestrator.RepositoryAssessments.AssessmentStoreTest do
  @moduledoc """
  Proof for `AssessmentStore.latest_completed/2`, hosted and device.

  `latest/2` already reads the newest assessment regardless of outcome.
  `latest_completed/2` is additive: it reads the newest assessment whose state
  is `"completed"`, skipping any newer pending or failed attempt on top of it.
  Task 12's readiness needs this because an approved execution profile stays
  bound to the completed assessment it was approved from, and a project may
  since have started a newer assessment that has not completed yet.
  """
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.DeviceStore.Local
  alias SddOrchestrator.{AccountsFixtures, ProjectsFixtures}

  alias SddOrchestrator.RepositoryAssessments.{
    AssessmentStore,
    RepositoryAssessment,
    RepositoryAssessmentCacheProvenance,
    RepositoryAssessmentResult,
    RepositoryBindingPreparation,
    RepositoryExecutionProfileProposalPayload,
    WorkerRepositoryExecutionProfileProposalEnvelope
  }

  @scanner_digest String.duplicate("a", 64)
  @disclosure_digest String.duplicate("b", 64)

  @proposal_fields %{
    commands: ["mix test"],
    required_checks: ["mix test"],
    allowed_scope: ["."],
    gaps: [],
    conflicts: [],
    multi_root_blockers: []
  }

  setup do
    store_path =
      Path.join(
        System.tmp_dir!(),
        "assessment-store-latest-completed-#{System.unique_integer([:positive])}/store.dets"
      )

    start_supervised!({Local, path: store_path})
    on_exit(fn -> File.rm_rf!(Path.dirname(store_path)) end)

    account = AccountsFixtures.account_fixture()
    workspace = ProjectsFixtures.workspace_fixture(account)
    hosted_project = ProjectsFixtures.registered_project(workspace, name: "Hosted store")

    {:ok, device_workspace} = Devices.establish_workspace()

    {:ok, device_project} =
      Devices.register_project(%{
        name: "Device store",
        repository_fingerprint: ProjectsFixtures.local_repository_metadata().fingerprint,
        status: "connected"
      })

    %{
      account: account,
      device_project: device_project,
      device_workspace: device_workspace,
      hosted_project: hosted_project
    }
  end

  for kind <- [:hosted, :device] do
    describe "latest_completed/2 (#{kind})" do
      @describetag kind: kind

      test "returns the older completed assessment when the newest is only pending", context do
        kind = context.kind
        completed = complete!(context, kind, commit(1), 1)
        _pending = put_pending!(context, kind, commit(2), 2)

        assert {:ok, latest} =
                 AssessmentStore.latest_completed(
                   viewer(context, kind),
                   project_id(context, kind)
                 )

        assert latest.id == completed.id
      end

      test "returns the older completed assessment when the newest failed", context do
        kind = context.kind
        completed = complete!(context, kind, commit(1), 1)
        _failed = fail!(context, kind, commit(2), 2)

        assert {:ok, latest} =
                 AssessmentStore.latest_completed(
                   viewer(context, kind),
                   project_id(context, kind)
                 )

        assert latest.id == completed.id
      end

      test "reports :not_found when no assessment has ever completed", context do
        kind = context.kind
        _pending = put_pending!(context, kind, commit(1), 1)

        assert {:error, :not_found} =
                 AssessmentStore.latest_completed(
                   viewer(context, kind),
                   project_id(context, kind)
                 )
      end

      test "returns the newest of several completed assessments", context do
        kind = context.kind
        _older = complete!(context, kind, commit(1), 1)
        newer = complete!(context, kind, commit(2), 2)

        assert {:ok, latest} =
                 AssessmentStore.latest_completed(
                   viewer(context, kind),
                   project_id(context, kind)
                 )

        assert latest.id == newer.id
      end
    end
  end

  ## Fixtures

  defp commit(n), do: String.duplicate(Integer.to_string(n), 40) |> String.slice(0, 40)

  defp project_id(context, :hosted), do: context.hosted_project.id
  defp project_id(context, :device), do: context.device_project.id

  defp viewer(context, :hosted), do: {:hosted, context.account.id}
  defp viewer(context, :device), do: {:device, context.device_workspace}

  defp now(offset_minutes) do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.add(offset_minutes, :minute)
  end

  defp complete!(context, kind, commit, offset_minutes) do
    now = now(offset_minutes)
    pending = build_pending!(context, kind, commit, now)
    assert {:ok, stored} = AssessmentStore.put(viewer(context, kind), pending)

    assert {:ok, command} = RepositoryAssessment.command(stored)
    assert {:ok, result} = RepositoryAssessmentResult.completed(command, completed_scan(command))

    assert {:ok, payload} =
             RepositoryExecutionProfileProposalPayload.new(result, @proposal_fields)

    assert {:ok, envelope} =
             WorkerRepositoryExecutionProfileProposalEnvelope.new(payload, command, result)

    {:ok, cache_key_sha256} = RepositoryAssessmentCacheProvenance.cache_key_sha256(command)
    {:ok, evidence_sha256} = RepositoryAssessmentCacheProvenance.evidence_sha256(result)

    assert {:ok, provenance} =
             RepositoryAssessmentCacheProvenance.new(%{
               source: "fresh_scan",
               cache_key_sha256: cache_key_sha256,
               evidence_sha256: evidence_sha256,
               cache_stored: true
             })

    assert {:ok, completed} =
             SddOrchestrator.RepositoryAssessments.finish_assessment(
               viewer(context, kind),
               project_id(context, kind),
               command,
               result,
               provenance,
               now: now,
               proposal_envelope: envelope
             )

    completed
  end

  defp fail!(context, kind, commit, offset_minutes) do
    now = now(offset_minutes)
    pending = build_pending!(context, kind, commit, now)
    assert {:ok, stored} = AssessmentStore.put(viewer(context, kind), pending)

    assert {:ok, command} = RepositoryAssessment.command(stored)
    assert {:ok, result} = RepositoryAssessmentResult.failed(command, "repository_unavailable")

    assert {:ok, failed} =
             SddOrchestrator.RepositoryAssessments.finish_assessment(
               viewer(context, kind),
               project_id(context, kind),
               command,
               result,
               now: now
             )

    failed
  end

  defp put_pending!(context, kind, commit, offset_minutes) do
    now = now(offset_minutes)
    pending = build_pending!(context, kind, commit, now)
    assert {:ok, stored} = AssessmentStore.put(viewer(context, kind), pending)
    stored
  end

  defp build_pending!(context, :hosted, commit, now) do
    build_pending(
      context.hosted_project.id,
      context.hosted_project.repository_provider,
      context.hosted_project.canonical_repository_id,
      commit,
      now
    )
  end

  defp build_pending!(context, :device, commit, now) do
    build_pending(
      context.device_project.id,
      context.device_project.repository_provider,
      context.device_project.repository_id,
      commit,
      now
    )
  end

  defp build_pending(project_id, provider, repository_id, commit, now) do
    assert {:ok, preparation} =
             RepositoryBindingPreparation.new(%{
               project_id: project_id,
               repository_provider: provider,
               repository_id: repository_id,
               root: ".",
               commit: commit,
               scanner_contract_digest: @scanner_digest,
               disclosure_digest: @disclosure_digest,
               worker_ref: Ecto.UUID.generate(),
               nonce: Ecto.UUID.generate(),
               issued_at: now,
               expires_at: DateTime.add(now, 120, :second)
             })

    assert {:ok, pending} = RepositoryAssessment.pending(preparation, now)
    pending
  end

  defp completed_scan(command) do
    %{
      protocol_version: command.version,
      assessment_id: command.assessment_id,
      project_id: command.project_id,
      repository: %{provider: command.repository_provider, id: command.repository_id},
      root: command.root,
      commit: command.commit,
      scanner_contract_digest: command.scanner_contract_digest,
      status: "completed",
      findings: [
        %{
          category: "instruction",
          path: "AGENTS.md",
          bytes: 12,
          sha256: String.duplicate("d", 64),
          line_count: 3
        }
      ],
      structure: [%{path: "lib", kind: "directory"}],
      stats: %{discovered_paths: 3, inspected_files: 1, bytes_read: 20}
    }
  end
end
