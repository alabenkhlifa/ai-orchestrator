defmodule SddOrchestrator.RepositoryAssessments.RepositoryExecutionProfileProposalEnvelopeTest do
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Accounts.DeviceWorkspace
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.DeviceStore.Local
  alias SddOrchestrator.Repo
  alias SddOrchestrator.RepositoryAssessments

  alias SddOrchestrator.RepositoryAssessments.{
    AssessmentStore,
    RepositoryAssessment,
    RepositoryAssessmentCacheProvenance,
    RepositoryAssessmentResult,
    RepositoryBindingPreparation,
    RepositoryExecutionProfileProposalEnvelope,
    RepositoryExecutionProfileProposalPayload,
    WorkerRepositoryExecutionProfileProposalEnvelope
  }

  alias SddOrchestratorWeb.RepositoryAssessmentLive

  import SddOrchestrator.AccountsFixtures
  import SddOrchestrator.HostedAccessFixtures
  import SddOrchestrator.ParticipationFixtures
  import SddOrchestrator.ProjectsFixtures

  @scanner_digest String.duplicate("a", 64)
  @disclosure_digest String.duplicate("b", 64)

  @owned_sources [
    "lib/sdd_orchestrator/repository_assessments/repository_execution_profile_proposal_envelope.ex",
    "lib/sdd_orchestrator/repository_assessments/assessment_store/hosted.ex",
    "lib/sdd_orchestrator/repository_assessments/assessment_store/device.ex"
  ]

  setup do
    store_path =
      Path.join(
        System.tmp_dir!(),
        "repository-assessment-envelope-#{System.unique_integer([:positive])}/store.dets"
      )

    start_supervised!({Local, path: store_path})
    on_exit(fn -> File.rm_rf!(Path.dirname(store_path)) end)

    {:ok, device_workspace} = Devices.establish_workspace()

    {:ok, device_project} =
      Devices.register_project(%{
        name: "Device proposal envelope",
        repository_fingerprint: "device-envelope-repository",
        status: "connected"
      })

    account = account_fixture()
    workspace = workspace_fixture(account)
    hosted_project = registered_project(workspace)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %{
      account: account,
      device_project: device_project,
      device_workspace: device_workspace,
      hosted_project: hosted_project,
      now: now,
      store_path: store_path
    }
  end

  test "a completed hosted delivery persists one exact assessment-bound envelope", context do
    pending = put_pending!(context, :hosted)
    command = command!(pending)
    result = completed_result!(command)
    provenance = provenance!(command, result)
    delivered = worker_envelope!(command, result)

    assert {:ok, completed} =
             RepositoryAssessments.finish_assessment(
               hosted_authority(context),
               pending.project_id,
               command,
               result,
               provenance,
               now: context.now,
               proposal_envelope: delivered
             )

    assert Repo.aggregate(RepositoryExecutionProfileProposalEnvelope, :count) == 1

    assert {:ok, %{assessment: read_assessment, envelope: envelope}} =
             RepositoryAssessments.proposal_envelope(
               hosted_authority(context),
               pending.project_id,
               pending.id
             )

    assert read_assessment == completed
    assert envelope.project_id == completed.project_id
    assert envelope.assessment_id == completed.id
    assert envelope.version == delivered.version
    assert envelope.envelope_digest == delivered.envelope_digest
    assert envelope.payload_digest == delivered.payload_digest
    assert envelope.result_sha256 == delivered.result_sha256
    assert envelope.cache_key_sha256 == provenance.cache_key_sha256
    assert envelope.evidence_sha256 == provenance.evidence_sha256
    assert envelope.cache_key_sha256 == completed.cache_key_sha256
    assert envelope.evidence_sha256 == completed.evidence_sha256

    assert RepositoryExecutionProfileProposalEnvelope.proposal_fields(envelope) == %{
             commands: ["mix test"],
             required_checks: ["mix test"],
             allowed_scope: ["."],
             gaps: ["missing_repository_instructions"],
             conflicts: [],
             multi_root_blockers: []
           }

    value = RepositoryExecutionProfileProposalEnvelope.to_value(envelope)
    assert RepositoryExecutionProfileProposalEnvelope.strict?(envelope)
    assert {:ok, restored} = RepositoryExecutionProfileProposalEnvelope.from_value(value)
    assert RepositoryExecutionProfileProposalEnvelope.to_value(restored) == value

    assert Enum.sort(Map.keys(value)) ==
             Enum.sort(
               ~w(allowed_scope assessment_id cache_key_sha256 commands conflicts envelope_digest) ++
                 ~w(evidence_sha256 gaps id inserted_at multi_root_blockers payload_digest) ++
                 ~w(project_id required_checks result_sha256 version)
             )

    serialized = inspect(value, limit: :infinity)
    refute serialized =~ "/Users/"
    refute serialized =~ "SECRET"
    refute serialized =~ "credential"
    refute serialized =~ "raw_diagnostic"
    refute serialized =~ "repository_index"
    refute serialized =~ "source_content"
    refute serialized =~ command.disclosure_digest
    refute serialized =~ command.worker_ref
  end

  test "canceled and failed deliveries refuse an envelope and persist none", context do
    for status <- [:canceled, :failed] do
      pending = put_pending!(context, :hosted)
      command = command!(pending)
      completed = completed_result!(command)
      delivered = worker_envelope!(command, completed)

      result =
        case status do
          :canceled -> elem(RepositoryAssessmentResult.canceled(command), 1)
          :failed -> elem(RepositoryAssessmentResult.failed(command, :stale_commit), 1)
        end

      assert {:error, :invalid_proposal_envelope} =
               RepositoryAssessments.finish_assessment(
                 hosted_authority(context),
                 pending.project_id,
                 command,
                 result,
                 nil,
                 now: context.now,
                 proposal_envelope: delivered
               )

      assert Repo.get!(RepositoryAssessment, pending.id).state == "pending_scan"

      assert {:ok, terminal} =
               RepositoryAssessments.finish_assessment(
                 hosted_authority(context),
                 pending.project_id,
                 command,
                 result,
                 now: context.now
               )

      assert terminal.state == Atom.to_string(status)
      assert Repo.aggregate(RepositoryExecutionProfileProposalEnvelope, :count) == 0

      assert {:error, :not_found} =
               RepositoryAssessments.proposal_envelope(
                 hosted_authority(context),
                 pending.project_id,
                 pending.id
               )
    end
  end

  test "missing, malformed, replaced, and prior-bound envelopes persist nothing", context do
    pending = put_pending!(context, :hosted)
    command = command!(pending)
    result = completed_result!(command)
    provenance = provenance!(command, result)
    delivered = worker_envelope!(command, result)

    other_pending = put_pending!(context, :hosted)
    other_command = command!(other_pending)
    other_result = completed_result!(other_command)

    invalid_envelopes = [
      nil,
      %{},
      Map.from_struct(delivered),
      %{delivered | commands: ["mix test", "make deploy"]},
      %{delivered | envelope_digest: String.duplicate("0", 64)},
      %{delivered | cache_key_sha256: String.duplicate("1", 64)},
      worker_envelope!(other_command, other_result)
    ]

    for invalid <- invalid_envelopes do
      assert {:error, :invalid_proposal_envelope} =
               RepositoryAssessments.finish_assessment(
                 hosted_authority(context),
                 pending.project_id,
                 command,
                 result,
                 provenance,
                 now: context.now,
                 proposal_envelope: invalid
               )

      assert Repo.get!(RepositoryAssessment, pending.id).state == "pending_scan"
      assert Repo.aggregate(RepositoryExecutionProfileProposalEnvelope, :count) == 0
    end

    assert {:ok, _completed} =
             RepositoryAssessments.finish_assessment(
               hosted_authority(context),
               pending.project_id,
               command,
               result,
               provenance,
               now: context.now,
               proposal_envelope: delivered
             )

    assert {:error, :invalid_proposal_envelope} =
             RepositoryAssessments.finish_assessment(
               hosted_authority(context),
               other_pending.project_id,
               other_command,
               other_result,
               provenance!(other_command, other_result),
               now: context.now,
               proposal_envelope: delivered
             )

    assert Repo.get!(RepositoryAssessment, other_pending.id).state == "pending_scan"
    assert Repo.aggregate(RepositoryExecutionProfileProposalEnvelope, :count) == 1
  end

  test "a completion stored without a verifiable envelope is never backfilled", context do
    pending = put_pending!(context, :hosted)
    command = command!(pending)
    result = completed_result!(command)
    provenance = provenance!(command, result)
    delivered = worker_envelope!(command, result)

    assert {:ok, _completed} =
             RepositoryAssessments.finish_assessment(
               hosted_authority(context),
               pending.project_id,
               command,
               result,
               provenance,
               now: context.now,
               proposal_envelope: delivered
             )

    assert {1, _rows} = Repo.delete_all(RepositoryExecutionProfileProposalEnvelope)

    assert {:error, :not_found} =
             RepositoryAssessments.proposal_envelope(
               hosted_authority(context),
               pending.project_id,
               pending.id
             )

    assert {:error, :already_terminal} =
             RepositoryAssessments.finish_assessment(
               hosted_authority(context),
               pending.project_id,
               command,
               result,
               provenance,
               now: DateTime.add(context.now, 1, :second),
               proposal_envelope: delivered
             )

    assert Repo.aggregate(RepositoryExecutionProfileProposalEnvelope, :count) == 0

    stored = Repo.get!(RepositoryAssessment, pending.id)
    assert stored.state == "completed"

    assert {:error, :stale} =
             AssessmentStore.transition(hosted_authority(context), stored, stored, delivered)

    assert Repo.aggregate(RepositoryExecutionProfileProposalEnvelope, :count) == 0
  end

  test "a stored envelope bound to another assessment is refused on read", context do
    pending = put_pending!(context, :hosted)
    command = command!(pending)
    result = completed_result!(command)

    assert {:ok, _completed} =
             RepositoryAssessments.finish_assessment(
               hosted_authority(context),
               pending.project_id,
               command,
               result,
               provenance!(command, result),
               now: context.now,
               proposal_envelope: worker_envelope!(command, result)
             )

    other_pending = put_pending!(context, :hosted)
    other_command = command!(other_pending)
    other_result = completed_result!(other_command)

    assert {:ok, _other_completed} =
             RepositoryAssessments.finish_assessment(
               hosted_authority(context),
               other_pending.project_id,
               other_command,
               other_result,
               provenance!(other_command, other_result),
               now: context.now,
               proposal_envelope: worker_envelope!(other_command, other_result)
             )

    stored = Repo.get_by!(RepositoryExecutionProfileProposalEnvelope, assessment_id: pending.id)

    assert {1, _rows} =
             from(envelope in RepositoryExecutionProfileProposalEnvelope,
               where: envelope.assessment_id == ^other_pending.id
             )
             |> Repo.delete_all()

    foreign = %{
      stored
      | id: Ecto.UUID.generate(),
        assessment_id: other_pending.id
    }

    assert {:ok, _inserted} =
             foreign
             |> RepositoryExecutionProfileProposalEnvelope.create_changeset()
             |> Repo.insert()

    assert {:error, :invalid_proposal_envelope} =
             RepositoryAssessments.proposal_envelope(
               hosted_authority(context),
               other_pending.project_id,
               other_pending.id
             )

    assert {:ok, %{envelope: envelope}} =
             RepositoryAssessments.proposal_envelope(
               hosted_authority(context),
               pending.project_id,
               pending.id
             )

    assert envelope.assessment_id == pending.id
  end

  test "device-authoritative envelopes survive restart and create no hosted copy", context do
    pending = put_pending!(context, :device)
    command = command!(pending)
    result = completed_result!(command)
    delivered = worker_envelope!(command, result)

    assert {:ok, completed} =
             RepositoryAssessments.finish_assessment(
               device_authority(context),
               pending.project_id,
               command,
               result,
               provenance!(command, result, %{source: "complete_cache", cache_stored: true}),
               now: context.now,
               proposal_envelope: delivered
             )

    assert completed.state == "completed"
    assert Repo.aggregate(RepositoryExecutionProfileProposalEnvelope, :count) == 0

    assert {:ok, %{envelope: envelope}} =
             RepositoryAssessments.proposal_envelope(
               device_authority(context),
               pending.project_id,
               pending.id
             )

    assert envelope.envelope_digest == delivered.envelope_digest

    stop_supervised!(Local)
    start_supervised!({Local, path: context.store_path})
    {:ok, workspace} = Devices.get_workspace()

    assert {:ok, %{assessment: restarted_assessment, envelope: restarted}} =
             RepositoryAssessments.proposal_envelope(
               {:device, workspace},
               pending.project_id,
               pending.id
             )

    assert restarted == envelope
    assert restarted_assessment == completed
    assert Repo.aggregate(RepositoryExecutionProfileProposalEnvelope, :count) == 0
  end

  test "device deliveries refuse an unverifiable envelope and store neither value", context do
    pending = put_pending!(context, :device)
    command = command!(pending)
    result = completed_result!(command)

    assert {:error, :invalid_proposal_envelope} =
             RepositoryAssessments.finish_assessment(
               device_authority(context),
               pending.project_id,
               command,
               result,
               provenance!(command, result),
               now: context.now,
               proposal_envelope: nil
             )

    assert {:ok, stored} =
             AssessmentStore.fetch(device_authority(context), pending.project_id, pending.id)

    assert stored.state == "pending_scan"

    assert {:error, :not_found} =
             Devices.get_repository_assessment_proposal_envelope(pending.project_id, pending.id)
  end

  test "an active participant reads the same verified envelope and strangers cannot", context do
    pending = put_pending!(context, :hosted)
    command = command!(pending)
    result = completed_result!(command)

    assert {:ok, _completed} =
             RepositoryAssessments.finish_assessment(
               hosted_authority(context),
               pending.project_id,
               command,
               result,
               provenance!(command, result),
               now: context.now,
               proposal_envelope: worker_envelope!(command, result)
             )

    participant_identity = hosted_identity_fixture()
    participant_fixture(context.hosted_project, participant_identity.hosted_identity)
    stranger_identity = hosted_identity_fixture()

    assert {:ok, %{envelope: participant_envelope}} =
             RepositoryAssessments.proposal_envelope(
               {:participant, participant_identity.account.id,
                participant_identity.hosted_identity.id},
               pending.project_id,
               pending.id
             )

    assert {:ok, %{envelope: owner_envelope}} =
             RepositoryAssessments.proposal_envelope(
               hosted_authority(context),
               pending.project_id,
               pending.id
             )

    assert participant_envelope == owner_envelope

    assert {:error, :not_found} =
             RepositoryAssessments.proposal_envelope(
               {:participant, stranger_identity.account.id, stranger_identity.hosted_identity.id},
               pending.project_id,
               pending.id
             )
  end

  test "cross-project, cross-account, and cross-workspace reads fail closed", context do
    pending = put_pending!(context, :hosted)
    command = command!(pending)
    result = completed_result!(command)

    assert {:ok, _completed} =
             RepositoryAssessments.finish_assessment(
               hosted_authority(context),
               pending.project_id,
               command,
               result,
               provenance!(command, result),
               now: context.now,
               proposal_envelope: worker_envelope!(command, result)
             )

    other_account = account_fixture()

    assert {:error, :not_found} =
             RepositoryAssessments.proposal_envelope(
               {:hosted, other_account.id},
               pending.project_id,
               pending.id
             )

    assert {:error, :not_found} =
             RepositoryAssessments.proposal_envelope(
               hosted_authority(context),
               Ecto.UUID.generate(),
               pending.id
             )

    assert {:error, :not_found} =
             RepositoryAssessments.proposal_envelope(
               device_authority(context),
               pending.project_id,
               pending.id
             )

    assert {:error, :not_found} =
             RepositoryAssessments.proposal_envelope(
               {:device, %DeviceWorkspace{id: Ecto.UUID.generate()}},
               pending.project_id,
               pending.id
             )
  end

  test "the processing disclosure names the minimized envelope transfer", _context do
    transfer = Enum.find(RepositoryAssessmentLive.disclosure_items(), &(&1.key == "transfer"))

    assert transfer.body =~ "minimized proposal envelope"
    assert transfer.body =~ "normalized commands"
    assert transfer.body =~ "No whole-repository source or hosted index is transferred."

    items = RepositoryAssessmentLive.disclosure_items()
    assert RepositoryAssessmentLive.disclosure_digest() == disclosure_digest(items)

    unchanged_boundary =
      Enum.map(items, fn item ->
        if item.key == "transfer",
          do: %{item | body: String.replace(item.body, "minimized proposal envelope", "envelope")},
          else: item
      end)

    refute disclosure_digest(unchanged_boundary) == RepositoryAssessmentLive.disclosure_digest()
  end

  test "authoritative envelope persistence uses no model, analytics, or worker transport",
       _context do
    forbidden = [
      "WorkerChannel",
      "WorkerSocket",
      "Phoenix.Channel",
      "Endpoint",
      "Analytics",
      "System.cmd",
      "Port.open",
      "File.write",
      "File.rm",
      "HTTPoison",
      ":httpc",
      "Finch",
      "openai",
      "anthropic"
    ]

    for path <- @owned_sources do
      source = File.read!(Path.join(File.cwd!(), path))

      for fragment <- forbidden do
        refute source =~ fragment,
               "#{path} must not reference #{fragment} in the authoritative envelope boundary"
      end
    end
  end

  defp put_pending!(context, kind) do
    pending = pending_assessment(context, kind)
    assert {:ok, stored} = AssessmentStore.put(authority(context, kind), pending)
    stored
  end

  defp pending_assessment(context, :hosted) do
    build_pending(
      context.hosted_project.id,
      context.hosted_project.repository_provider,
      context.hosted_project.canonical_repository_id,
      context.now
    )
  end

  defp pending_assessment(context, :device) do
    build_pending(
      context.device_project.id,
      context.device_project.repository_provider,
      context.device_project.repository_id,
      context.now
    )
  end

  defp build_pending(project_id, provider, repository_id, now) do
    assert {:ok, preparation} =
             RepositoryBindingPreparation.new(%{
               project_id: project_id,
               repository_provider: provider,
               repository_id: repository_id,
               root: ".",
               commit: String.duplicate("1", 40),
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

  defp command!(assessment) do
    assert {:ok, command} = RepositoryAssessment.command(assessment)
    command
  end

  defp completed_result!(command) do
    assert {:ok, result} = RepositoryAssessmentResult.completed(command, completed_scan(command))
    result
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
          category: "check",
          path: "Makefile",
          bytes: 10,
          sha256: String.duplicate("c", 64),
          line_count: 2
        }
      ],
      structure: [%{path: "lib", kind: "directory"}],
      stats: %{discovered_paths: 3, inspected_files: 1, bytes_read: 10}
    }
  end

  defp worker_envelope!(command, result) do
    assert {:ok, payload} =
             RepositoryExecutionProfileProposalPayload.new(result, %{
               commands: ["mix test"],
               required_checks: ["mix test"],
               allowed_scope: [command.root],
               gaps: ["missing_repository_instructions"],
               conflicts: [],
               multi_root_blockers: []
             })

    assert {:ok, envelope} =
             WorkerRepositoryExecutionProfileProposalEnvelope.new(payload, command, result)

    envelope
  end

  defp provenance!(command, result, overrides \\ %{}) do
    {:ok, cache_key_sha256} = RepositoryAssessmentCacheProvenance.cache_key_sha256(command)
    {:ok, evidence_sha256} = RepositoryAssessmentCacheProvenance.evidence_sha256(result)

    attrs =
      Map.merge(
        %{
          source: "fresh_scan",
          cache_key_sha256: cache_key_sha256,
          evidence_sha256: evidence_sha256,
          cache_stored: true
        },
        overrides
      )

    assert {:ok, provenance} = RepositoryAssessmentCacheProvenance.new(attrs)
    provenance
  end

  defp disclosure_digest(items) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary(items, [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  defp authority(context, :hosted), do: hosted_authority(context)
  defp authority(context, :device), do: device_authority(context)
  defp hosted_authority(context), do: {:hosted, context.account.id}
  defp device_authority(context), do: {:device, context.device_workspace}
end
