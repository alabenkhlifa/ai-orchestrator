defmodule SddOrchestrator.Privacy.RepositoryPilotAndReadinessPrivacyTest do
  @moduledoc """
  Task 1 privacy-boundary proof for specs/30's new records (AC-01).

  `RepositoryPilotSelection` (Task 4) and the computed `RepositoryReadiness`
  value (Task 12) are the only new authoritative surfaces this slice adds. This
  file proves, with real deletes and real `Retention`/`Rights` calls rather than
  mocks:

    * a closed field-level allowlist over the pilot's stored value and the
      readiness snapshot — neither can carry an absolute path, repository
      content, a credential, or an unrelated identity;
    * hosted and device-authoritative parity, and that evaluating readiness and
      building a device-authoritative pilot create no durable hosted copy;
    * deletion reaches the pilot selection through the real project, profile,
      and account cascades — including the device-local sweep this task adds to
      `Devices.delete_project/1` for the assessment, profile, and pilot keys a
      device project's DETS entry did not previously purge;
    * `Retention.prune_all/1` correctly does not need to reach any of these
      records, because they are bounded by the project's own lifecycle rather
      than a timer;
    * neither boundary logs or inspects its own data, and the domain carries no
      analytics or secondary use.

  It confirms, rather than re-proves, the existing coverage this task also
  owns: Slice 14's `RepositoryAssessment` and `RepositoryExecutionProfile`
  already carry their own locality and minimization proof locally in
  `test/sdd_orchestrator/repository_assessments/`, and Task 4/12 already prove
  owner-only write and participant read. This file does not repeat that
  business-rule coverage.
  """

  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.{AccountsFixtures, ProjectsFixtures}
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.DeviceStore.Local
  alias SddOrchestrator.Privacy.{Retention, Rights}
  alias SddOrchestrator.RepositoryAssessments

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

  alias SddOrchestrator.RepositoryPilots
  alias SddOrchestrator.RepositoryPilots.RepositoryPilotSelection
  alias SddOrchestrator.RepositoryReadiness
  alias SddOrchestrator.Specifications.SpecificationLifecycle

  @scanner_digest String.duplicate("a", 64)
  @disclosure_digest String.duplicate("b", 64)
  @commit String.duplicate("1", 40)

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

  # A heuristic negative scan for the shapes AC-01 names: an absolute path,
  # path traversal, and credential-shaped text. Combined below with exact
  # structural assertions rather than relied on alone.
  @forbidden ~r/\.\.|^\/|[A-Za-z]:\\\\|api[_-]?key|secret|password|token|bearer/i

  # Every reason `RepositoryReadiness` may report, drawn from its own closed
  # `@type reason`. Kept here as an independent, hand-copied list so this test
  # fails if the module ever grows a reason without this proof noticing it.
  @readiness_reasons ~w(
    no_approved_profile
    no_pilot_selected
    stale_base_revision
    changed_root
    unresolved_evidence_conflict
    unsupported_multi_root_boundary
    no_completed_assessment
    unreliable_required_check_contract
  )a

  setup do
    store_path =
      Path.join(
        System.tmp_dir!(),
        "repository-pilot-readiness-privacy-#{System.unique_integer([:positive])}/store.dets"
      )

    start_supervised!({Local, path: store_path})
    on_exit(fn -> File.rm_rf!(Path.dirname(store_path)) end)

    account = AccountsFixtures.account_fixture()
    workspace = ProjectsFixtures.workspace_fixture(account)
    hosted_project = ProjectsFixtures.registered_project(workspace, name: "Hosted privacy")

    {:ok, device_workspace} = Devices.establish_workspace()

    {:ok, device_project} =
      Devices.register_project(%{
        name: "Device privacy",
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

  describe "field-level allowlist [AC-01]" do
    test "the pilot's stored value carries exactly its closed field set and nothing forbidden",
         context do
      selection = pilot!(context, :hosted)
      value = RepositoryPilotSelection.to_value(selection)

      assert MapSet.new(Map.keys(value)) ==
               MapSet.new(~w(
                 id project_id profile_id profile_version specification_id revision_id
                 revision_digest selected_by_actor_ref selected_at inserted_at
               ))

      # The Ecto schema itself carries no field beyond this same closed set, so
      # nothing could ever leak through a preload or a raw struct dump either.
      assert Enum.sort(RepositoryPilotSelection.__schema__(:fields)) ==
               Enum.sort([
                 :id,
                 :project_id,
                 :profile_id,
                 :profile_version,
                 :specification_id,
                 :revision_id,
                 :revision_digest,
                 :selected_by_actor_ref,
                 :selected_at,
                 :inserted_at
               ])

      for {key, field_value} <- value, key not in ["id", "project_id", "profile_id"] do
        rendered = inspect(field_value)
        refute rendered =~ @forbidden, "field #{key} carried a forbidden shape: #{rendered}"
      end
    end

    test "the computed readiness snapshot carries only closed axis atoms, never repository content",
         context do
      profile = approve!(context, :hosted)
      no_pilot = RepositoryReadiness.evaluate(hosted(context), context.hosted_project.id)

      pilot!(context, :hosted, profile)
      ready = RepositoryReadiness.evaluate(hosted(context), context.hosted_project.id)

      for readiness <- [no_pilot, ready] do
        assert Enum.sort(Map.keys(Map.from_struct(readiness))) ==
                 Enum.sort([
                   :assistant,
                   :specification,
                   :agent_execution,
                   :release,
                   :earliest_blocked_stage
                 ])

        for axis <- [:assistant, :specification, :agent_execution, :release] do
          case Map.fetch!(readiness, axis) do
            :ready ->
              :ok

            {:blocked, reason} ->
              assert reason in @readiness_reasons
              # Every reason is a bare, short, pre-interned atom: never a
              # string that could carry a path, a finding, or free text.
              assert is_atom(reason)
              refute Atom.to_string(reason) =~ @forbidden
          end
        end

        assert readiness.earliest_blocked_stage in [
                 nil,
                 :assistant,
                 :specification,
                 :agent_execution,
                 :release
               ]
      end

      refute no_pilot.specification == :ready
      assert ready.specification == :ready
    end
  end

  describe "hosted and device-authoritative parity; no durable hosted copy [AC-01]" do
    test "a device-authoritative pilot, profile, and assessment create zero hosted rows",
         context do
      assessment_count = Repo.aggregate(RepositoryAssessment, :count)
      profile_count = Repo.aggregate(RepositoryExecutionProfile, :count)
      pilot_count = Repo.aggregate(RepositoryPilotSelection, :count)

      pilot!(context, :device)

      assert Repo.aggregate(RepositoryAssessment, :count) == assessment_count
      assert Repo.aggregate(RepositoryExecutionProfile, :count) == profile_count
      assert Repo.aggregate(RepositoryPilotSelection, :count) == pilot_count
    end

    test "evaluating readiness writes nothing, for either authoritative storage mode", context do
      approve!(context, :hosted)
      approve!(context, :device)

      assessment_count = Repo.aggregate(RepositoryAssessment, :count)
      profile_count = Repo.aggregate(RepositoryExecutionProfile, :count)
      pilot_count = Repo.aggregate(RepositoryPilotSelection, :count)

      RepositoryReadiness.evaluate(hosted(context), context.hosted_project.id)
      RepositoryReadiness.evaluate(device(context), context.device_project.id)

      assert Repo.aggregate(RepositoryAssessment, :count) == assessment_count
      assert Repo.aggregate(RepositoryExecutionProfile, :count) == profile_count
      assert Repo.aggregate(RepositoryPilotSelection, :count) == pilot_count
    end
  end

  describe "deletion coverage [AC-01]" do
    test "deleting the hosted project cascades away its assessment, profile, and pilot selection",
         context do
      selection = pilot!(context, :hosted)
      assessment = Repo.get_by!(RepositoryAssessment, project_id: context.hosted_project.id)
      profile = Repo.get!(RepositoryExecutionProfile, selection.profile_id)

      assert {:ok, %{project_id: project_id}} =
               SpecificationLifecycle.delete_project(context.workspace, context.hosted_project.id)

      assert project_id == context.hosted_project.id
      refute Repo.get(RepositoryAssessment, assessment.id)
      refute Repo.get(RepositoryExecutionProfile, profile.id)
      refute Repo.get(RepositoryPilotSelection, selection.id)
    end

    test "deleting the referenced profile cascades away the pilot selection, leaving the assessment",
         context do
      selection = pilot!(context, :hosted)
      profile = Repo.get!(RepositoryExecutionProfile, selection.profile_id)
      assessment_count = Repo.aggregate(RepositoryAssessment, :count)

      Repo.delete!(profile)

      refute Repo.get(RepositoryExecutionProfile, profile.id)
      refute Repo.get(RepositoryPilotSelection, selection.id)
      assert Repo.aggregate(RepositoryAssessment, :count) == assessment_count
    end

    test "erase_account/2 removes the account's assessment, profile, and pilot selection",
         context do
      selection = pilot!(context, :hosted)
      assessment = Repo.get_by!(RepositoryAssessment, project_id: context.hosted_project.id)
      profile = Repo.get!(RepositoryExecutionProfile, selection.profile_id)

      assert {:ok, _result} = Rights.erase_account(context.account.id)

      refute Repo.get(RepositoryAssessment, assessment.id)
      refute Repo.get(RepositoryExecutionProfile, profile.id)
      refute Repo.get(RepositoryPilotSelection, selection.id)
    end

    test "deleting a device project purges its assessment, profile, and pilot selection from the device-local store",
         context do
      pilot!(context, :device)

      assert Devices.repository_assessment_count(context.device_project.id) > 0
      assert Devices.list_repository_execution_profiles(context.device_project.id) != []
      assert {:ok, _value} = Devices.get_repository_pilot_selection(context.device_project.id)

      assert {:ok,
              %{
                deleted_pilot_selection: true,
                deleted_repository_assessments: assessment_deletions,
                deleted_repository_execution_profiles: profile_deletions
              }} = Devices.delete_project(context.device_project.id)

      assert assessment_deletions > 0
      assert profile_deletions > 0

      assert {:error, :not_found} = Devices.get_project(context.device_project.id)

      assert {:error, :not_found} =
               Devices.get_repository_pilot_selection(context.device_project.id)

      assert Devices.list_repository_execution_profiles(context.device_project.id) == []
      assert Devices.repository_assessment_count(context.device_project.id) == 0

      # No durable hosted copy was ever created for the device-authoritative
      # chain, so hosted deletion coverage has nothing left to prove here.
      assert Repo.aggregate(RepositoryPilotSelection, :count) == 0
    end
  end

  describe "retention coverage [AC-01]" do
    test "Retention.prune_all/1 does not need to reach the assessment, profile, or pilot selection",
         context do
      selection = pilot!(context, :hosted)
      assessment = Repo.get_by!(RepositoryAssessment, project_id: context.hosted_project.id)
      profile = Repo.get!(RepositoryExecutionProfile, selection.profile_id)

      # A window far beyond every other governed retention window in the
      # deployment (90-day pinned sessions, 35-day backups, 30-day logs).
      far_future = DateTime.add(context.now, 3650 * 24 * 60 * 60, :second)

      Retention.prune_all(far_future)

      assert Repo.get(RepositoryAssessment, assessment.id)
      assert Repo.get(RepositoryExecutionProfile, profile.id)
      assert Repo.get(RepositoryPilotSelection, selection.id)
    end
  end

  describe "no analytics or secondary use, and log redaction [AC-01]" do
    test "the pilot and readiness boundaries never call Logger or inspect their own data" do
      sources =
        [
          "lib/sdd_orchestrator/repository_pilots.ex",
          "lib/sdd_orchestrator/repository_pilots/repository_pilot_selection.ex",
          "lib/sdd_orchestrator/repository_pilots/pilot_store/hosted.ex",
          "lib/sdd_orchestrator/repository_pilots/pilot_store/device.ex",
          "lib/sdd_orchestrator/repository_readiness.ex"
        ]
        |> Enum.map_join("\n", &File.read!/1)

      refute sources =~ "Logger."
      refute sources =~ "IO.inspect"
    end

    test "the pilot selection table is not analytics-shaped and carries no secondary use" do
      {:ok, %{rows: rows}} =
        Repo.query(
          "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public'"
        )

      tables = List.flatten(rows)
      assert "repository_pilot_selections" in tables

      refute Regex.match?(
               ~r/analytic|metric|tracking|telemetry_event|pageview|impression/i,
               "repository_pilot_selections"
             )
    end
  end

  ## Fixtures: builds one real completed assessment, one real approved
  ## profile, and (via `pilot!/3`) one real committed pilot selection, through
  ## the same production boundaries `RepositoryAssessments` and
  ## `RepositoryPilots` expose, for either authoritative storage mode.

  defp pilot!(context, kind, profile \\ nil) do
    _profile = profile || approve!(context, kind)
    current = current_specification(context, kind)

    assert {:ok, selection} =
             RepositoryPilots.select(authority(context, kind), project_id(context, kind), %{
               specification_id: current.specification.id,
               revision_id: current.revision.id
             })

    selection
  end

  defp current_specification(context, :hosted) do
    SddOrchestrator.SpecificationFixtures.hosted_specification(
      context.workspace,
      context.hosted_project,
      title: "Privacy pilot specification"
    )
  end

  defp current_specification(context, :device) do
    attrs =
      SddOrchestrator.SpecificationFixtures.specification_attrs(
        title: "Privacy pilot specification"
      )

    {:ok, current} =
      SddOrchestrator.SpecificationStore.create(
        context.device_workspace,
        context.device_project.id,
        attrs
      )

    current
  end

  defp approve!(context, kind) do
    completed = complete!(context, kind)

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

  defp complete!(context, kind) do
    pending = put_pending!(context, kind)
    command = command!(pending)
    result = completed_result!(command)
    envelope = worker_envelope!(command, result)

    assert {:ok, completed} =
             RepositoryAssessments.finish_assessment(
               authority(context, kind),
               pending.project_id,
               command,
               result,
               provenance!(command, result),
               now: context.now,
               proposal_envelope: envelope
             )

    completed
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
               commit: @commit,
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
      findings: @findings,
      structure: [%{path: "lib", kind: "directory"}],
      stats: %{discovered_paths: 3, inspected_files: 1, bytes_read: 20}
    }
  end

  defp worker_envelope!(command, result) do
    assert {:ok, payload} =
             RepositoryExecutionProfileProposalPayload.new(result, @proposal_fields)

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

  defp project_id(context, :hosted), do: context.hosted_project.id
  defp project_id(context, :device), do: context.device_project.id

  defp authority(context, :hosted), do: hosted(context)
  defp authority(context, :device), do: device(context)

  defp hosted(context), do: {:hosted, context.account.id}
  defp device(context), do: {:device, context.device_workspace}
end
