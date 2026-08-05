defmodule SddOrchestrator.RepositoryPilotsTest do
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Delivery.Feature
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.DeviceStore.Local
  alias SddOrchestrator.HostedAccessFixtures
  alias SddOrchestrator.ParticipationFixtures
  alias SddOrchestrator.Repo
  alias SddOrchestrator.RepositoryAssessments
  alias SddOrchestrator.RepositoryPilots
  alias SddOrchestrator.RepositoryPilots.RepositoryPilotSelection
  alias SddOrchestrator.SpecificationStore

  alias SddOrchestrator.{
    AccountsFixtures,
    ProjectsFixtures,
    SpecificationFixtures
  }

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

  # The exact document text a pilot must never carry into its own record.
  @documents %{
    requirements: "# Requirements\n\nSECRET-REQUIREMENTS-BODY",
    design: "# Design\n\nSECRET-DESIGN-BODY",
    tasks: "# Tasks\n\nSECRET-TASKS-BODY"
  }

  setup do
    store_path =
      Path.join(
        System.tmp_dir!(),
        "repository-pilots-#{System.unique_integer([:positive])}/store.dets"
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

  test "the hosted owner commits one current revision as the pilot", context do
    profile = approve!(context, :hosted)
    current = hosted_specification(context)
    backlog = Repo.aggregate(Feature, :count)

    assert {:ok, selection} =
             RepositoryPilots.select(hosted(context), context.hosted_project.id, %{
               specification_id: current.specification.id,
               revision_id: current.revision.id
             })

    assert selection.project_id == context.hosted_project.id
    assert selection.specification_id == current.specification.id
    assert selection.revision_id == current.revision.id
    assert selection.revision_digest == current.revision.content_digest
    assert selection.profile_id == profile.id
    assert selection.profile_version == profile.version
    assert selection.selected_by_actor_ref == context.account.id

    assert {:ok, stored} = RepositoryPilots.current(hosted(context), context.hosted_project.id)
    assert stored.id == selection.id
    assert stored.revision_id == current.revision.id

    # Selection imports no backlog item and writes nothing to the repository.
    assert Repo.aggregate(Feature, :count) == backlog
  end

  test "the persisted pilot references the specification and copies no document", context do
    approve!(context, :hosted)
    current = hosted_specification(context)

    assert {:ok, selection} =
             RepositoryPilots.select(hosted(context), context.hosted_project.id, %{
               specification_id: current.specification.id,
               revision_id: current.revision.id
             })

    # The record has no field that could hold a title or a document at all.
    assert selection |> Map.from_struct() |> Map.keys() |> Enum.sort() == [
             :__meta__,
             :id,
             :inserted_at,
             :profile,
             :profile_id,
             :profile_version,
             :project,
             :project_id,
             :revision_digest,
             :revision_id,
             :selected_at,
             :selected_by_actor_ref,
             :specification_id
           ]

    rendered = inspect(RepositoryPilotSelection.to_value(selection))

    refute rendered =~ "SECRET-REQUIREMENTS-BODY"
    refute rendered =~ "SECRET-DESIGN-BODY"
    refute rendered =~ "SECRET-TASKS-BODY"
    refute rendered =~ "Pilot specification title"

    assert [row] = Repo.all(RepositoryPilotSelection)
    refute inspect(row) =~ "SECRET-"
  end

  test "the selectable list exposes identity and title only, never a document", context do
    approve!(context, :hosted)
    current = hosted_specification(context)

    assert {:ok, [selectable]} =
             RepositoryPilots.selectable_specifications(
               hosted(context),
               context.hosted_project.id
             )

    assert selectable.id == current.specification.id
    assert selectable.revision_id == current.revision.id
    assert selectable.title == "Pilot specification title"

    assert selectable |> Map.from_struct() |> Map.keys() |> Enum.sort() ==
             [:id, :revision_id, :title]

    rendered = inspect(selectable)
    refute rendered =~ "SECRET-REQUIREMENTS-BODY"
    refute rendered =~ "SECRET-DESIGN-BODY"
    refute rendered =~ "SECRET-TASKS-BODY"
  end

  test "a revision that is no longer current is refused at commit", context do
    approve!(context, :hosted)
    current = hosted_specification(context)

    assert {:ok, appended} =
             SpecificationStore.append_revision(
               context.workspace,
               context.hosted_project.id,
               current.specification.id,
               current.revision.id,
               %{
                 revision_id: Ecto.UUID.generate(),
                 actor_ref: "owner",
                 documents:
                   SpecificationFixtures.documents(%{requirements: "# Requirements\n\nv2"})
               }
             )

    assert appended.revision.id != current.revision.id

    assert {:error, :stale_revision} =
             RepositoryPilots.select(hosted(context), context.hosted_project.id, %{
               specification_id: current.specification.id,
               revision_id: current.revision.id
             })

    assert {:error, :not_found} =
             RepositoryPilots.current(hosted(context), context.hosted_project.id)

    assert Repo.aggregate(RepositoryPilotSelection, :count) == 0

    # The freshly current revision commits.
    assert {:ok, selection} =
             RepositoryPilots.select(hosted(context), context.hosted_project.id, %{
               specification_id: current.specification.id,
               revision_id: appended.revision.id
             })

    assert selection.revision_id == appended.revision.id
  end

  test "a participant may read the stored pilot but never select or list", context do
    approve!(context, :hosted)
    current = hosted_specification(context)

    assert {:ok, _selection} =
             RepositoryPilots.select(hosted(context), context.hosted_project.id, %{
               specification_id: current.specification.id,
               revision_id: current.revision.id
             })

    participant = participant!(context)

    assert {:error, :unauthorized} =
             RepositoryPilots.select(participant, context.hosted_project.id, %{
               specification_id: current.specification.id,
               revision_id: current.revision.id
             })

    assert {:error, :unauthorized} =
             RepositoryPilots.selectable_specifications(participant, context.hosted_project.id)

    assert {:ok, stored} = RepositoryPilots.current(participant, context.hosted_project.id)
    assert stored.specification_id == current.specification.id
    assert stored.revision_id == current.revision.id
    refute inspect(stored) =~ "SECRET-"
  end

  test "re-selecting replaces the single current pilot", context do
    approve!(context, :hosted)
    first = hosted_specification(context)

    second =
      SpecificationFixtures.hosted_specification(
        context.workspace,
        context.hosted_project,
        title: "Second specification",
        documents: @documents
      )

    assert {:ok, initial} =
             RepositoryPilots.select(hosted(context), context.hosted_project.id, %{
               specification_id: first.specification.id,
               revision_id: first.revision.id
             })

    assert {:ok, replacement} =
             RepositoryPilots.select(hosted(context), context.hosted_project.id, %{
               specification_id: second.specification.id,
               revision_id: second.revision.id
             })

    assert replacement.specification_id == second.specification.id
    refute replacement.specification_id == initial.specification_id
    assert Repo.aggregate(RepositoryPilotSelection, :count) == 1

    assert {:ok, stored} = RepositoryPilots.current(hosted(context), context.hosted_project.id)
    assert stored.specification_id == second.specification.id
  end

  test "the device owner commits a pilot that leaves no hosted copy", context do
    hosted_rows = Repo.aggregate(RepositoryPilotSelection, :count)
    profile = approve!(context, :device)
    current = device_specification(context)

    assert {:ok, [selectable]} =
             RepositoryPilots.selectable_specifications(
               device(context),
               context.device_project.id
             )

    assert selectable.id == current.specification.id

    assert selectable |> Map.from_struct() |> Map.keys() |> Enum.sort() == [
             :id,
             :revision_id,
             :title
           ]

    assert {:ok, selection} =
             RepositoryPilots.select(device(context), context.device_project.id, %{
               "specification_id" => current.specification.id,
               "revision_id" => current.revision.id
             })

    assert selection.project_id == context.device_project.id
    assert selection.revision_digest == current.revision.content_digest
    assert selection.profile_version == profile.version
    assert selection.selected_by_actor_ref == context.device_workspace.id

    assert {:ok, stored} = RepositoryPilots.current(device(context), context.device_project.id)
    assert stored.id == selection.id
    refute inspect(stored) =~ "SECRET-"

    # A device-authoritative pilot creates no durable hosted copy.
    assert Repo.aggregate(RepositoryPilotSelection, :count) == hosted_rows
  end

  test "a device pilot is refused when its submitted revision is stale", context do
    approve!(context, :device)
    current = device_specification(context)

    assert {:error, :stale_revision} =
             RepositoryPilots.select(device(context), context.device_project.id, %{
               specification_id: current.specification.id,
               revision_id: Ecto.UUID.generate()
             })

    assert {:error, :not_found} =
             RepositoryPilots.current(device(context), context.device_project.id)
  end

  test "a project with no approved profile cannot be piloted", context do
    current = hosted_specification(context)

    assert {:error, :no_approved_profile} =
             RepositoryPilots.select(hosted(context), context.hosted_project.id, %{
               specification_id: current.specification.id,
               revision_id: current.revision.id
             })

    assert Repo.aggregate(RepositoryPilotSelection, :count) == 0
  end

  test "an unsupported or foreign authority fails closed", context do
    approve!(context, :hosted)
    current = hosted_specification(context)
    outsider = AccountsFixtures.account_fixture()

    attrs = %{
      specification_id: current.specification.id,
      revision_id: current.revision.id
    }

    assert {:error, :unsupported_authority} =
             RepositoryPilots.select(:root, context.hosted_project.id, attrs)

    assert {:error, :unsupported_authority} =
             RepositoryPilots.selectable_specifications(:root, context.hosted_project.id)

    assert {:error, :unauthorized} =
             RepositoryPilots.select({:hosted, outsider.id}, context.hosted_project.id, attrs)

    # A hosted authority may never reach a device project, and the reverse.
    assert {:error, :unauthorized} =
             RepositoryPilots.select(hosted(context), context.device_project.id, attrs)

    assert {:error, :unauthorized} =
             RepositoryPilots.select(device(context), context.hosted_project.id, attrs)

    assert {:error, :invalid_selection} =
             RepositoryPilots.select(hosted(context), context.hosted_project.id, %{})

    assert {:error, :not_found} = RepositoryPilots.current(:root, context.hosted_project.id)
    assert Repo.aggregate(RepositoryPilotSelection, :count) == 0
  end

  ## Specification fixtures

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

  ## Participation fixtures

  defp participant!(context) do
    invited = HostedAccessFixtures.hosted_identity_fixture()
    ParticipationFixtures.participant_fixture(context.hosted_project, invited.hosted_identity)
    {:participant, invited.account.id, invited.hosted_identity.id}
  end

  ## Assessment and profile fixtures

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
    pending = put_pending!(context, kind, context.now)
    command = command!(pending)
    result = completed_result!(command)
    delivered = worker_envelope!(command, result)

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

  defp put_pending!(context, kind, now) do
    pending = pending_assessment(context, kind, now)
    assert {:ok, stored} = AssessmentStore.put(authority(context, kind), pending)
    stored
  end

  defp pending_assessment(context, :hosted, now) do
    build_pending(
      context.hosted_project.id,
      context.hosted_project.repository_provider,
      context.hosted_project.canonical_repository_id,
      now
    )
  end

  defp pending_assessment(context, :device, now) do
    build_pending(
      context.device_project.id,
      context.device_project.repository_provider,
      context.device_project.repository_id,
      now
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

  defp authority(context, :hosted), do: hosted(context)
  defp authority(context, :device), do: device(context)

  defp hosted(context), do: {:hosted, context.account.id}
  defp device(context), do: {:device, context.device_workspace}
end
