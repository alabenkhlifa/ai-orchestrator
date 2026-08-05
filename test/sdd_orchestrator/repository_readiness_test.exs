defmodule SddOrchestrator.RepositoryReadinessTest.AssessmentStoreOverride do
  @moduledoc false
  @behaviour SddOrchestrator.RepositoryAssessments.AssessmentStore

  alias SddOrchestrator.Accounts.DeviceWorkspace
  alias SddOrchestrator.RepositoryAssessments.AssessmentStore.{Device, Hosted}

  # Everything delegates to the real hosted/device adapter except
  # `latest_completed/2`, which a test may override through the process
  # dictionary. Each ExUnit test runs in its own process, so the override is
  # naturally test-scoped and needs no explicit teardown.
  @impl true
  def put(authority, assessment), do: dispatch(authority).put(authority, assessment)

  @impl true
  def transition(authority, pending, terminal, envelope),
    do: dispatch(authority).transition(authority, pending, terminal, envelope)

  @impl true
  def fetch(authority, project_id, assessment_id),
    do: dispatch(authority).fetch(authority, project_id, assessment_id)

  @impl true
  def fetch_envelope(viewer, project_id, assessment_id),
    do: viewer_dispatch(viewer).fetch_envelope(viewer, project_id, assessment_id)

  @impl true
  def latest(viewer, project_id), do: viewer_dispatch(viewer).latest(viewer, project_id)

  @impl true
  def latest_completed(viewer, project_id) do
    case Process.get(:readiness_test_latest_completed) do
      nil -> viewer_dispatch(viewer).latest_completed(viewer, project_id)
      :not_found -> {:error, :not_found}
      assessment -> {:ok, assessment}
    end
  end

  @impl true
  def count(authority, project_id), do: dispatch(authority).count(authority, project_id)

  defp dispatch({:hosted, _account_id}), do: Hosted
  defp dispatch({:device, %DeviceWorkspace{}}), do: Device

  defp viewer_dispatch({:hosted, _account_id}), do: Hosted
  defp viewer_dispatch({:participant, _account_id, _identity_id}), do: Hosted
  defp viewer_dispatch({:device, %DeviceWorkspace{}}), do: Device
end

defmodule SddOrchestrator.RepositoryReadinessTest.ProfileStoreOverride do
  @moduledoc false
  @behaviour SddOrchestrator.RepositoryAssessments.ProfileStore

  alias SddOrchestrator.Accounts.DeviceWorkspace
  alias SddOrchestrator.RepositoryAssessments.ProfileStore.{Device, Hosted}

  # `list/2` is the only function Task 12's readiness reads. A test may
  # override it to a synthetic profile list built directly through the real
  # `RepositoryExecutionProfileProposal.new/2` and `RepositoryExecutionProfile.
  # approved/4` constructors, without persisting anything.
  @impl true
  def append(authority, assessment, proposal, actor_ref, approved_at),
    do: dispatch(authority).append(authority, assessment, proposal, actor_ref, approved_at)

  @impl true
  def list(viewer, project_id) do
    case Process.get(:readiness_test_profiles) do
      nil -> viewer_dispatch(viewer).list(viewer, project_id)
      profiles -> profiles
    end
  end

  @impl true
  def count(authority, project_id), do: length(list(authority, project_id))

  defp dispatch({:hosted, _account_id}), do: Hosted
  defp dispatch({:device, %DeviceWorkspace{}}), do: Device

  defp viewer_dispatch({:hosted, _account_id}), do: Hosted
  defp viewer_dispatch({:participant, _account_id, _identity_id}), do: Hosted
  defp viewer_dispatch({:device, %DeviceWorkspace{}}), do: Device
end

defmodule SddOrchestrator.RepositoryReadinessTest.PilotStoreOverride do
  @moduledoc false
  @behaviour SddOrchestrator.RepositoryPilots.PilotStore

  alias SddOrchestrator.Accounts.DeviceWorkspace
  alias SddOrchestrator.RepositoryPilots.PilotStore.{Device, Hosted}

  @impl true
  def put(authority, selection), do: dispatch(authority).put(authority, selection)

  @impl true
  def fetch(viewer, project_id) do
    case Process.get(:readiness_test_pilot) do
      nil -> viewer_dispatch(viewer).fetch(viewer, project_id)
      :not_found -> {:error, :not_found}
      selection -> {:ok, selection}
    end
  end

  defp dispatch({:hosted, _account_id}), do: Hosted
  defp dispatch({:device, %DeviceWorkspace{}}), do: Device

  defp viewer_dispatch({:hosted, _account_id}), do: Hosted
  defp viewer_dispatch({:participant, _account_id, _identity_id}), do: Hosted
  defp viewer_dispatch({:device, %DeviceWorkspace{}}), do: Device
end

defmodule SddOrchestrator.RepositoryReadinessTest do
  @moduledoc """
  Proof for `SddOrchestrator.RepositoryReadiness`.

  Two kinds of coverage live here. The "real wiring" tests run the four axes
  against the actual hosted and device `AssessmentStore`, `ProfileStore`, and
  `PilotStore` adapters end to end, proving dispatch and authority parity. The
  "business rule" tests hold one real completed assessment and approved
  profile fixed and vary exactly one field at a time — through the override
  modules above — to isolate each blocked reason and prove the four axes are
  independent rather than a strict ladder.
  """
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.DeviceStore.Local
  alias SddOrchestrator.{AccountsFixtures, HostedAccessFixtures, ParticipationFixtures}
  alias SddOrchestrator.ProjectsFixtures
  alias SddOrchestrator.RepositoryAssessments
  alias SddOrchestrator.RepositoryPilots
  alias SddOrchestrator.RepositoryPilots.RepositoryPilotSelection
  alias SddOrchestrator.RepositoryReadiness
  alias SddOrchestrator.SpecificationFixtures
  alias SddOrchestrator.SpecificationStore

  alias SddOrchestrator.RepositoryReadinessTest.{
    AssessmentStoreOverride,
    PilotStoreOverride,
    ProfileStoreOverride
  }

  alias SddOrchestrator.RepositoryAssessments.{
    AssessmentStore,
    RepositoryAssessment,
    RepositoryAssessmentCacheProvenance,
    RepositoryAssessmentResult,
    RepositoryBindingPreparation,
    RepositoryExecutionProfile,
    RepositoryExecutionProfileProposal,
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

  @findings [
    %{
      category: "instruction",
      path: "AGENTS.md",
      bytes: 12,
      sha256: String.duplicate("d", 64),
      line_count: 3
    }
  ]

  @structure [
    %{path: "lib", kind: "directory"},
    %{path: "packages/api", kind: "directory"}
  ]

  @opts [
    assessment_store: AssessmentStoreOverride,
    profile_store: ProfileStoreOverride,
    pilot_store: PilotStoreOverride
  ]

  setup do
    store_path =
      Path.join(
        System.tmp_dir!(),
        "repository-readiness-#{System.unique_integer([:positive])}/store.dets"
      )

    start_supervised!({Local, path: store_path})
    on_exit(fn -> File.rm_rf!(Path.dirname(store_path)) end)

    account = AccountsFixtures.account_fixture()
    workspace = ProjectsFixtures.workspace_fixture(account)
    hosted_project = ProjectsFixtures.registered_project(workspace, name: "Readiness hosted")

    {:ok, device_workspace} = Devices.establish_workspace()

    {:ok, device_project} =
      Devices.register_project(%{
        name: "Readiness device",
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

  ## Real wiring: no approved profile, no pilot, and the fully ready case,
  ## proven against the actual hosted and device adapters (no overrides).

  for kind <- [:hosted, :device] do
    describe "real wiring (#{kind})" do
      @describetag kind: kind

      test "blocks every axis with :no_approved_profile when nothing was approved", context do
        kind = context.kind
        readiness = RepositoryReadiness.evaluate(viewer(context, kind), project_id(context, kind))

        assert readiness.assistant == {:blocked, :no_approved_profile}
        assert readiness.specification == {:blocked, :no_approved_profile}
        assert readiness.agent_execution == {:blocked, :no_approved_profile}
        assert readiness.release == {:blocked, :no_approved_profile}
        assert readiness.earliest_blocked_stage == :assistant
      end

      test "blocks specification, agent execution, and release with :no_pilot_selected once a profile is approved",
           context do
        kind = context.kind
        approve!(context, kind, @proposal_fields)

        readiness = RepositoryReadiness.evaluate(viewer(context, kind), project_id(context, kind))

        assert readiness.assistant == :ready
        assert readiness.specification == {:blocked, :no_pilot_selected}
        assert readiness.agent_execution == {:blocked, :no_pilot_selected}
        assert readiness.release == {:blocked, :no_pilot_selected}
        assert readiness.earliest_blocked_stage == :specification
      end

      test "reports every axis ready once a matching profile is approved and a pilot is selected",
           context do
        kind = context.kind
        approve!(context, kind, @proposal_fields)
        select_pilot!(context, kind)

        readiness = RepositoryReadiness.evaluate(viewer(context, kind), project_id(context, kind))

        assert readiness.assistant == :ready
        assert readiness.specification == :ready
        assert readiness.agent_execution == :ready
        assert readiness.release == :ready
        assert readiness.earliest_blocked_stage == nil
      end
    end
  end

  test "an accepted hosted participant reads the exact same readiness as the owner", context do
    approve!(context, :hosted, @proposal_fields)
    select_pilot!(context, :hosted)

    owner_readiness =
      RepositoryReadiness.evaluate({:hosted, context.account.id}, context.hosted_project.id)

    identity = HostedAccessFixtures.hosted_identity_fixture()
    ParticipationFixtures.participant_fixture(context.hosted_project, identity.hosted_identity)

    participant_readiness =
      RepositoryReadiness.evaluate(
        {:participant, nil, identity.hosted_identity.id},
        context.hosted_project.id
      )

    assert participant_readiness == owner_readiness
    assert participant_readiness.assistant == :ready
    assert participant_readiness.release == :ready
  end

  ## Business rules: one real completed assessment and approved profile stay
  ## fixed; each test overrides exactly one field to isolate one blocked
  ## reason and to prove the four axes do not cascade past specification.

  describe "agent-execution and release business rules (hosted)" do
    # A real completed assessment and a real approved profile are built once so
    # the default (non-overridden) path through `profile_review/3` — `latest/2`,
    # `fetch_envelope/3`, and the baseline `profile_store.list/2` — succeeds for
    # real in every test below. Each test then overrides at most one of
    # `readiness_test_latest_completed` or `readiness_test_profiles` to isolate
    # exactly one business rule.
    setup context do
      completed = complete!(context, :hosted, @commit, @proposal_fields)

      assert {:ok, review} =
               RepositoryAssessments.profile_review(
                 {:hosted, context.account.id},
                 completed.project_id
               )

      assert {:ok, _profile} =
               RepositoryAssessments.approve_profile(
                 {:hosted, context.account.id},
                 completed.project_id,
                 review.proposal
               )

      Process.put(:readiness_test_pilot, %RepositoryPilotSelection{})
      %{completed: completed}
    end

    test "blocks agent execution with :stale_base_revision when the latest completed commit moved",
         context do
      Process.put(:readiness_test_latest_completed, %{context.completed | commit: @other_commit})

      readiness = evaluate(context, :hosted)

      assert readiness.agent_execution == {:blocked, :stale_base_revision}
      assert readiness.release == :ready
      assert readiness.specification == :ready
      assert readiness.earliest_blocked_stage == :agent_execution
    end

    test "blocks agent execution with :changed_root when the latest completed root moved",
         context do
      Process.put(:readiness_test_latest_completed, %{context.completed | root: "packages/api"})

      readiness = evaluate(context, :hosted)

      assert readiness.agent_execution == {:blocked, :changed_root}
      assert readiness.release == :ready
      assert readiness.earliest_blocked_stage == :agent_execution
    end

    test "blocks agent execution with :unresolved_evidence_conflict without blocking release",
         context do
      profile =
        approved_profile(context.completed, %{
          @proposal_fields
          | conflicts: ["ambiguous_command_evidence"]
        })

      Process.put(:readiness_test_profiles, [profile])

      readiness = evaluate(context, :hosted)

      assert readiness.agent_execution == {:blocked, :unresolved_evidence_conflict}
      assert readiness.release == :ready
      assert readiness.earliest_blocked_stage == :agent_execution
    end

    test "blocks agent execution with :unsupported_multi_root_boundary without blocking release",
         context do
      profile =
        approved_profile(
          context.completed,
          %{@proposal_fields | multi_root_blockers: ["packages/api"]}
        )

      Process.put(:readiness_test_profiles, [profile])

      readiness = evaluate(context, :hosted)

      assert readiness.agent_execution == {:blocked, :unsupported_multi_root_boundary}
      assert readiness.release == :ready
      assert readiness.earliest_blocked_stage == :agent_execution
    end

    test "blocks release with :unreliable_required_check_contract when required_checks is empty, without blocking agent execution",
         context do
      profile = approved_profile(context.completed, %{@proposal_fields | required_checks: []})
      Process.put(:readiness_test_profiles, [profile])

      readiness = evaluate(context, :hosted)

      assert readiness.release == {:blocked, :unreliable_required_check_contract}
      assert readiness.agent_execution == :ready
      assert readiness.earliest_blocked_stage == :release
    end

    test "blocks release with :unreliable_required_check_contract when the profile carries a missing_required_checks gap, without blocking agent execution",
         context do
      profile =
        approved_profile(
          context.completed,
          %{@proposal_fields | gaps: ["missing_required_checks"]}
        )

      Process.put(:readiness_test_profiles, [profile])

      readiness = evaluate(context, :hosted)

      assert readiness.release == {:blocked, :unreliable_required_check_contract}
      assert readiness.agent_execution == :ready
      assert readiness.earliest_blocked_stage == :release
    end
  end

  ## Evaluation helper

  defp evaluate(context, kind),
    do: RepositoryReadiness.evaluate(viewer(context, kind), project_id(context, kind), @opts)

  ## Viewer/project helpers

  defp project_id(context, :hosted), do: context.hosted_project.id
  defp project_id(context, :device), do: context.device_project.id

  defp viewer(context, :hosted), do: {:hosted, context.account.id}
  defp viewer(context, :device), do: {:device, context.device_workspace}

  ## Pure in-memory assessment/proposal/profile builders (business rules)

  defp approved_profile(%RepositoryAssessment{} = assessment, proposal_fields) do
    assert {:ok, proposal} = RepositoryExecutionProfileProposal.new(assessment, proposal_fields)

    assert {:ok, profile} =
             RepositoryExecutionProfile.approved(
               proposal,
               Ecto.UUID.generate(),
               1,
               DateTime.utc_now()
             )

    profile
  end

  ## Real hosted/device fixtures (approve!/complete!/select_pilot! run through
  ## the actual stores, so `latest/2`, `fetch_envelope/3`, and the baseline
  ## `profile_store.list/2` all succeed for real before any override kicks in)

  defp approve!(context, kind, proposal_fields) do
    completed = complete!(context, kind, @commit, proposal_fields)

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
    assert {:ok, command} = RepositoryAssessment.command(pending)
    assert {:ok, result} = RepositoryAssessmentResult.completed(command, completed_scan(command))

    assert {:ok, payload} = RepositoryExecutionProfileProposalPayload.new(result, proposal_fields)

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
             RepositoryAssessments.finish_assessment(
               authority(context, kind),
               pending.project_id,
               command,
               result,
               provenance,
               now: context.now,
               proposal_envelope: envelope
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
      structure: @structure,
      stats: %{discovered_paths: 4, inspected_files: 1, bytes_read: 20}
    }
  end

  ## Pilot fixtures

  defp select_pilot!(context, kind) do
    current = specification!(context, kind)

    assert {:ok, selection} =
             RepositoryPilots.select(authority(context, kind), project_id(context, kind), %{
               specification_id: current.specification.id,
               revision_id: current.revision.id
             })

    selection
  end

  defp specification!(context, :hosted) do
    SpecificationFixtures.hosted_specification(
      context.workspace,
      context.hosted_project,
      title: "Readiness pilot specification",
      documents: documents()
    )
  end

  defp specification!(context, :device) do
    attrs =
      SpecificationFixtures.specification_attrs(
        title: "Readiness pilot specification",
        documents: documents()
      )

    {:ok, current} =
      SpecificationStore.create(context.device_workspace, context.device_project.id, attrs)

    current
  end

  defp documents do
    %{
      requirements: "# Requirements\n\nReadiness pilot.",
      design: "# Design\n\nReadiness pilot.",
      tasks: "# Tasks\n\n- [ ] Readiness pilot."
    }
  end

  defp authority(context, :hosted), do: {:hosted, context.account.id}
  defp authority(context, :device), do: {:device, context.device_workspace}
end
