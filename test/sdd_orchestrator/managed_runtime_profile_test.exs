defmodule SddOrchestrator.ManagedRuntimeProfileTest do
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.DeviceStore.Local
  alias SddOrchestrator.HostedAccessFixtures
  alias SddOrchestrator.ManagedRuntimeProfile
  alias SddOrchestrator.ParticipationFixtures
  alias SddOrchestrator.Repo
  alias SddOrchestrator.RepositoryAssessments
  alias SddOrchestrator.RepositoryAssessments.RepositoryAssessment, as: RepositoryAssessmentSchema
  alias SddOrchestrator.RepositoryPilots
  alias SddOrchestrator.RepositoryPilots.RepositoryPilotSelection
  alias SddOrchestrator.SpecificationStore

  alias SddOrchestrator.{
    AccountsFixtures,
    ProjectsFixtures,
    SpecificationFixtures
  }

  alias SddOrchestrator.Delivery.Feature

  alias SddOrchestrator.RepositoryAssessments.{
    AssessmentStore,
    RepositoryAssessment,
    RepositoryAssessmentCacheProvenance,
    RepositoryAssessmentResult,
    RepositoryBindingPreparation,
    RepositoryExecutionProfile,
    RepositoryExecutionProfileProposalPayload,
    WorkerRepositoryExecutionProfileProposalEnvelope
  }

  @scanner_digest String.duplicate("a", 64)
  @disclosure_digest String.duplicate("b", 64)
  @commit String.duplicate("1", 40)
  @other_commit String.duplicate("2", 40)

  @proposal_fields %{
    commands: ["mix test"],
    required_checks: ["mix test"],
    allowed_scope: ["."],
    gaps: [],
    conflicts: [],
    multi_root_blockers: []
  }

  @unreliable_proposal_fields %{
    @proposal_fields
    | required_checks: [],
      gaps: ["missing_required_checks"]
  }

  @findings [
    %{
      category: "instruction",
      path: "AGENTS.md",
      bytes: 12,
      sha256: String.duplicate("d", 64),
      line_count: 3
    }
  ]

  @documents %{
    requirements: "# Requirements\n\nSECRET-REQUIREMENTS-BODY",
    design: "# Design\n\nSECRET-DESIGN-BODY",
    tasks: "# Tasks\n\nSECRET-TASKS-BODY"
  }

  @skill_names ~w(add-spec update-spec implement-spec review-spec)

  setup do
    store_path =
      Path.join(
        System.tmp_dir!(),
        "managed-runtime-profile-#{System.unique_integer([:positive])}/store.dets"
      )

    start_supervised!({Local, path: store_path})
    on_exit(fn -> File.rm_rf!(Path.dirname(store_path)) end)

    account = AccountsFixtures.account_fixture()
    workspace = ProjectsFixtures.workspace_fixture(account)
    hosted_project = ProjectsFixtures.registered_project(workspace, name: "Hosted pilot")

    {:ok, device_workspace} = Devices.establish_workspace()

    {:ok, device_project} =
      Devices.register_project(%{
        name: "Device pilot",
        repository_fingerprint: ProjectsFixtures.local_repository_metadata().fingerprint,
        status: "connected"
      })

    %{
      account: account,
      device_project: device_project,
      device_workspace: device_workspace,
      hosted_project: hosted_project,
      now: DateTime.utc_now() |> DateTime.truncate(:second),
      workspace: workspace
    }
  end

  describe "build/3 — deterministic value, hosted" do
    test "builds the exact allowlisted value from the approved profile, pilot, and readiness",
         context do
      profile = approve!(context, :hosted, @proposal_fields)
      pilot = select_pilot!(context, :hosted, profile)

      assert {:ok, value} =
               ManagedRuntimeProfile.build(hosted(context), context.hosted_project.id)

      assert value.profile_version == profile.version
      assert value.repository_provider == profile.repository_provider
      assert value.repository_id == profile.repository_id
      assert value.root == profile.root
      assert value.base_revision == profile.base_revision
      assert value.assessment_digest == profile.assessment_digest
      assert value.commands == profile.commands
      assert value.required_checks == profile.required_checks
      assert value.allowed_scope == profile.allowed_scope
      assert value.pilot_specification_id == pilot.specification_id
      assert value.pilot_revision_id == pilot.revision_id
      assert value.pilot_revision_digest == pilot.revision_digest

      assert value.readiness == %{
               "assistant" => "ready",
               "specification" => "ready",
               "agent_execution" => "ready",
               "release" => "ready",
               "earliest_blocked_stage" => nil
             }

      assert MapSet.new(Map.from_struct(value) |> Map.keys() |> Enum.map(&Atom.to_string/1)) ==
               MapSet.new([
                 "profile_version",
                 "repository_provider",
                 "repository_id",
                 "root",
                 "base_revision",
                 "assessment_digest",
                 "commands",
                 "required_checks",
                 "allowed_scope",
                 "pilot_specification_id",
                 "pilot_revision_id",
                 "pilot_revision_digest",
                 "readiness",
                 "runtime_skill_refs",
                 "digest"
               ])

      assert ManagedRuntimeProfile.strict?(value)
    end

    test "the serialization and digest are deterministic across two builds", context do
      profile = approve!(context, :hosted, @proposal_fields)
      select_pilot!(context, :hosted, profile)

      assert {:ok, first} =
               ManagedRuntimeProfile.build(hosted(context), context.hosted_project.id)

      assert {:ok, second} =
               ManagedRuntimeProfile.build(hosted(context), context.hosted_project.id)

      assert ManagedRuntimeProfile.to_value(first) == ManagedRuntimeProfile.to_value(second)
      assert first.digest == second.digest
      assert String.match?(first.digest, ~r/\A[0-9a-f]{64}\z/)
    end

    test "carries the four canonical skills as content-digest-versioned references", context do
      profile = approve!(context, :hosted, @proposal_fields)
      select_pilot!(context, :hosted, profile)

      assert {:ok, value} =
               ManagedRuntimeProfile.build(hosted(context), context.hosted_project.id)

      expected =
        Enum.map(@skill_names, fn name ->
          content = File.read!(Path.join([File.cwd!(), ".agents", "skills", name, "SKILL.md"]))
          version = :sha256 |> :crypto.hash(content) |> Base.encode16(case: :lower)
          %{"name" => name, "version" => version}
        end)

      assert Enum.sort_by(value.runtime_skill_refs, & &1["name"]) ==
               Enum.sort_by(expected, & &1["name"])

      assert Enum.all?(value.runtime_skill_refs, fn ref ->
               String.match?(ref["version"], ~r/\A[0-9a-f]{64}\z/)
             end)
    end
  end

  describe "build/3 — refusals" do
    test "refuses when no profile is approved", context do
      assert {:error, :no_approved_profile} =
               ManagedRuntimeProfile.build(hosted(context), context.hosted_project.id)
    end

    test "refuses when no pilot is selected", context do
      approve!(context, :hosted, @proposal_fields)

      assert {:error, :no_pilot_selected} =
               ManagedRuntimeProfile.build(hosted(context), context.hosted_project.id)
    end

    test "refuses once a newer profile has been approved than the pilot references", context do
      first_profile = approve!(context, :hosted, @proposal_fields)
      select_pilot!(context, :hosted, first_profile)

      second_profile =
        approve!(
          %{context | now: DateTime.add(context.now, 60, :second)},
          :hosted,
          @proposal_fields
        )

      assert second_profile.version > first_profile.version

      assert {:error, :stale_profile} =
               ManagedRuntimeProfile.build(hosted(context), context.hosted_project.id)
    end

    test "refuses once the pilot's specification revision is no longer current", context do
      profile = approve!(context, :hosted, @proposal_fields)
      pilot = select_pilot!(context, :hosted, profile)

      assert {:ok, _appended} =
               SpecificationStore.append_revision(
                 context.workspace,
                 context.hosted_project.id,
                 pilot.specification_id,
                 pilot.revision_id,
                 %{
                   revision_id: Ecto.UUID.generate(),
                   actor_ref: "owner",
                   documents:
                     SpecificationFixtures.documents(%{requirements: "# Requirements\n\nv2"})
                 }
               )

      assert {:error, :stale_pilot_revision} =
               ManagedRuntimeProfile.build(hosted(context), context.hosted_project.id)
    end

    test "refuses a participant and any other unsupported authority", context do
      profile = approve!(context, :hosted, @proposal_fields)
      select_pilot!(context, :hosted, profile)

      identity = HostedAccessFixtures.hosted_identity_fixture()
      ParticipationFixtures.participant_fixture(context.hosted_project, identity.hosted_identity)
      participant = {:participant, identity.account.id, identity.hosted_identity.id}

      assert {:error, :unsupported_authority} =
               ManagedRuntimeProfile.build(participant, context.hosted_project.id)

      assert {:error, :unsupported_authority} =
               ManagedRuntimeProfile.build(:not_an_authority, context.hosted_project.id)
    end
  end

  describe "readiness is staged, not gated on, availability" do
    test "the value still builds when agent-execution readiness is blocked by a stale base revision",
         context do
      profile = approve!(context, :hosted, @proposal_fields)
      select_pilot!(context, :hosted, profile)

      # A later completed assessment moves the commit forward without a new
      # approved profile: readiness reads this as stale, but the pilot's own
      # profile and revision references are unaffected, so the value still
      # builds — the blocker is a readiness reading, not a build refusal.
      complete!(
        %{context | now: DateTime.add(context.now, 60, :second)},
        :hosted,
        @other_commit,
        @proposal_fields
      )

      assert {:ok, value} =
               ManagedRuntimeProfile.build(hosted(context), context.hosted_project.id)

      assert value.readiness["assistant"] == "ready"
      assert value.readiness["specification"] == "ready"
      assert value.readiness["agent_execution"] == "blocked:stale_base_revision"
      assert value.readiness["earliest_blocked_stage"] == "agent_execution"
    end

    test "the value still builds when release readiness is blocked by an unreliable check contract",
         context do
      profile = approve!(context, :hosted, @unreliable_proposal_fields)
      select_pilot!(context, :hosted, profile)

      assert {:ok, value} =
               ManagedRuntimeProfile.build(hosted(context), context.hosted_project.id)

      assert value.readiness["agent_execution"] == "ready"
      assert value.readiness["release"] == "blocked:unreliable_required_check_contract"
      assert value.readiness["earliest_blocked_stage"] == "release"
    end
  end

  describe "downstream compatibility and integrity" do
    test "the value survives a JSON round trip unchanged", context do
      profile = approve!(context, :hosted, @proposal_fields)
      select_pilot!(context, :hosted, profile)

      assert {:ok, value} =
               ManagedRuntimeProfile.build(hosted(context), context.hosted_project.id)

      encoded = ManagedRuntimeProfile.to_value(value)
      json_round_tripped = encoded |> Jason.encode!() |> Jason.decode!()

      assert json_round_tripped == encoded
      assert {:ok, restored} = ManagedRuntimeProfile.from_value(json_round_tripped)
      assert restored == value
    end

    test "from_value/1 refuses an unknown field, a missing field, and a tampered digest",
         context do
      profile = approve!(context, :hosted, @proposal_fields)
      select_pilot!(context, :hosted, profile)

      assert {:ok, value} =
               ManagedRuntimeProfile.build(hosted(context), context.hosted_project.id)

      encoded = ManagedRuntimeProfile.to_value(value)

      assert {:error, :invalid_managed_runtime_profile} =
               ManagedRuntimeProfile.from_value(Map.put(encoded, "unexpected_field", "x"))

      assert {:error, :invalid_managed_runtime_profile} =
               ManagedRuntimeProfile.from_value(Map.delete(encoded, "root"))

      assert {:error, :invalid_managed_runtime_profile} =
               ManagedRuntimeProfile.from_value(
                 Map.put(encoded, "digest", String.duplicate("0", 64))
               )

      assert {:error, :invalid_managed_runtime_profile} =
               ManagedRuntimeProfile.from_value(
                 put_in(encoded, ["readiness"], Map.put(encoded["readiness"], "unexpected", "x"))
               )

      assert {:error, :invalid_managed_runtime_profile} =
               ManagedRuntimeProfile.from_value(
                 Map.put(encoded, "runtime_skill_refs", [%{"name" => "add-spec"}])
               )

      assert {:error, :invalid_managed_runtime_profile} =
               ManagedRuntimeProfile.from_value("not a map")
    end

    test "the value never carries specification document content", context do
      profile = approve!(context, :hosted, @proposal_fields)
      select_pilot!(context, :hosted, profile)

      assert {:ok, value} =
               ManagedRuntimeProfile.build(hosted(context), context.hosted_project.id)

      rendered = inspect(ManagedRuntimeProfile.to_value(value))

      refute rendered =~ "SECRET-REQUIREMENTS-BODY"
      refute rendered =~ "SECRET-DESIGN-BODY"
      refute rendered =~ "SECRET-TASKS-BODY"
    end

    test "building the value creates or changes no repository, assessment, or backlog record",
         context do
      profile = approve!(context, :hosted, @proposal_fields)
      select_pilot!(context, :hosted, profile)

      counts_before = record_counts()

      assert {:ok, _value} =
               ManagedRuntimeProfile.build(hosted(context), context.hosted_project.id)

      assert record_counts() == counts_before
    end
  end

  describe "build/3 — device authority parity" do
    test "builds the equivalent value for the owning device authority", context do
      profile = approve!(context, :device, @proposal_fields)
      pilot = select_pilot!(context, :device, profile)

      assert {:ok, value} =
               ManagedRuntimeProfile.build(device(context), context.device_project.id)

      assert value.profile_version == profile.version
      assert value.pilot_specification_id == pilot.specification_id
      assert value.pilot_revision_id == pilot.revision_id
      assert value.readiness["agent_execution"] == "ready"
      assert ManagedRuntimeProfile.strict?(value)
    end
  end

  ## Specification and pilot fixtures

  defp hosted_specification(context) do
    SpecificationFixtures.hosted_specification(
      context.workspace,
      context.hosted_project,
      title: "Pilot specification title",
      documents: @documents
    )
  end

  defp device_specification(context) do
    attrs =
      SpecificationFixtures.specification_attrs(
        title: "Pilot specification title",
        documents: @documents
      )

    {:ok, current} =
      SpecificationStore.create(context.device_workspace, context.device_project.id, attrs)

    current
  end

  defp select_pilot!(context, :hosted, _profile) do
    current = hosted_specification_or_current(context)

    assert {:ok, selection} =
             RepositoryPilots.select(hosted(context), context.hosted_project.id, %{
               specification_id: current.specification.id,
               revision_id: current.revision.id
             })

    selection
  end

  defp select_pilot!(context, :device, _profile) do
    current = device_specification_or_current(context)

    assert {:ok, selection} =
             RepositoryPilots.select(device(context), context.device_project.id, %{
               specification_id: current.specification.id,
               revision_id: current.revision.id
             })

    selection
  end

  defp hosted_specification_or_current(context) do
    case Process.get({:hosted_specification, context.hosted_project.id}) do
      nil ->
        current = hosted_specification(context)
        Process.put({:hosted_specification, context.hosted_project.id}, current)
        current

      current ->
        current
    end
  end

  defp device_specification_or_current(context) do
    case Process.get({:device_specification, context.device_project.id}) do
      nil ->
        current = device_specification(context)
        Process.put({:device_specification, context.device_project.id}, current)
        current

      current ->
        current
    end
  end

  ## Participation fixtures already imported above via ParticipationFixtures

  ## Assessment and profile fixtures

  defp approve!(context, kind, proposal_fields),
    do: approve!(context, kind, @commit, proposal_fields)

  defp approve!(context, kind, commit, proposal_fields) do
    completed = complete!(context, kind, commit, proposal_fields)

    assert {:ok, review} =
             RepositoryAssessments.profile_review(authority(context, kind), completed.project_id)

    assert {:ok, profile} =
             RepositoryAssessments.approve_profile(
               authority(context, kind),
               completed.project_id,
               review.proposal
             )

    profile
  end

  defp complete!(context, kind, commit, proposal_fields) do
    pending = put_pending!(context, kind, commit, context.now)
    command = command!(pending)
    result = completed_result!(command, proposal_fields)
    delivered = worker_envelope!(command, result, proposal_fields)

    assert {:ok, completed} =
             RepositoryAssessments.finish_assessment(
               authority(context, kind),
               pending.project_id,
               command,
               result,
               provenance!(command, result),
               now: context.now,
               proposal_envelope: delivered
             )

    completed
  end

  defp put_pending!(context, kind, commit, now) do
    pending = pending_assessment(context, kind, commit, now)
    assert {:ok, stored} = AssessmentStore.put(authority(context, kind), pending)
    stored
  end

  defp pending_assessment(context, :hosted, commit, now) do
    build_pending(
      context.hosted_project.id,
      context.hosted_project.repository_provider,
      context.hosted_project.canonical_repository_id,
      commit,
      now
    )
  end

  defp pending_assessment(context, :device, commit, now) do
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

  defp command!(assessment) do
    assert {:ok, command} = RepositoryAssessment.command(assessment)
    command
  end

  defp completed_result!(command, proposal_fields) do
    assert {:ok, result} = RepositoryAssessmentResult.completed(command, completed_scan(command))
    _ = proposal_fields
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
      findings: @findings,
      structure: [%{path: "lib", kind: "directory"}],
      stats: %{discovered_paths: 3, inspected_files: 1, bytes_read: 20}
    }
  end

  defp worker_envelope!(command, result, proposal_fields) do
    assert {:ok, payload} = RepositoryExecutionProfileProposalPayload.new(result, proposal_fields)

    assert {:ok, envelope} =
             WorkerRepositoryExecutionProfileProposalEnvelope.new(payload, command, result)

    envelope
  end

  defp provenance!(command, result) do
    {:ok, cache_key_sha256} = RepositoryAssessmentCacheProvenance.cache_key_sha256(command)
    {:ok, evidence_sha256} = RepositoryAssessmentCacheProvenance.evidence_sha256(result)

    assert {:ok, provenance} =
             RepositoryAssessmentCacheProvenance.new(%{
               source: "fresh_scan",
               cache_key_sha256: cache_key_sha256,
               evidence_sha256: evidence_sha256,
               cache_stored: true
             })

    provenance
  end

  defp record_counts do
    %{
      assessments: Repo.aggregate(RepositoryAssessmentSchema, :count),
      profiles: Repo.aggregate(RepositoryExecutionProfile, :count),
      pilots: Repo.aggregate(RepositoryPilotSelection, :count),
      backlog: Repo.aggregate(Feature, :count)
    }
  end

  defp authority(context, :hosted), do: hosted(context)
  defp authority(context, :device), do: device(context)

  defp hosted(context), do: {:hosted, context.account.id}
  defp device(context), do: {:device, context.device_workspace}
end
