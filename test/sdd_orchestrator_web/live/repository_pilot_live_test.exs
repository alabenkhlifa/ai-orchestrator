defmodule SddOrchestratorWeb.RepositoryPilotLiveTest do
  use SddOrchestratorWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias SddOrchestrator.AccountsFixtures
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.DeviceStore.Local
  alias SddOrchestrator.HostedAccess.{SessionCookie, Sessions}
  alias SddOrchestrator.HostedAccessFixtures
  alias SddOrchestrator.ParticipationFixtures
  alias SddOrchestrator.ProjectsFixtures
  alias SddOrchestrator.Repo
  alias SddOrchestrator.RepositoryAssessments
  alias SddOrchestrator.RepositoryPilots
  alias SddOrchestrator.RepositoryPilots.RepositoryPilotSelection
  alias SddOrchestrator.SpecificationFixtures
  alias SddOrchestrator.SpecificationStore

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

  @documents %{
    requirements: "# Requirements\n\nSECRET-REQUIREMENTS-BODY",
    design: "# Design\n\nSECRET-DESIGN-BODY",
    tasks: "# Tasks\n\nSECRET-TASKS-BODY"
  }

  setup %{conn: conn} do
    store_path =
      Path.join(
        System.tmp_dir!(),
        "repository-pilot-live-#{System.unique_integer([:positive])}/store.dets"
      )

    start_supervised!({Local, path: store_path})
    on_exit(fn -> File.rm_rf!(Path.dirname(store_path)) end)

    %{conn: owner_conn, account: account} = register_and_log_in_account(%{conn: conn})
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
      owner_conn: owner_conn,
      workspace: workspace
    }
  end

  test "the hosted owner sees the selectable specifications and commits one", context do
    profile = approve!(context, :hosted)
    current = hosted_specification(context)

    {:ok, view, html} = live(context.owner_conn, hosted_path(context))

    assert html =~ ~s(data-screen="repository-pilot")
    assert html =~ ~s(data-pilot-stage="select")
    assert html =~ ~s(data-pilot-role="owner")
    assert has_element?(view, "[data-no-pilot]")
    refute has_element?(view, "[data-read-only]")

    assert has_element?(view, ~s([data-selectable-specification="#{current.specification.id}"]))
    assert render(view) =~ "Pilot specification title"

    # The screen shows a reference, never the specification's document text.
    refute render(view) =~ "SECRET-REQUIREMENTS-BODY"
    refute render(view) =~ "SECRET-DESIGN-BODY"
    refute render(view) =~ "SECRET-TASKS-BODY"

    render_click(view, "select_pilot", %{
      "specification_id" => current.specification.id,
      "revision_id" => current.revision.id
    })

    assert render(view) =~ ~s(data-pilot-stage="selected")

    assert view |> element("[data-pilot-message]") |> render() =~
             "Pilot set to this specification"

    assert field(view, "specification") =~ current.specification.id
    assert field(view, "revision") =~ current.revision.id
    assert field(view, "revision-digest") =~ current.revision.content_digest
    assert field(view, "profile-version") =~ to_string(profile.version)
    refute has_element?(view, "[data-no-pilot]")
    assert has_element?(view, "[data-current-pilot]")

    assert {:ok, stored} = RepositoryPilots.current(hosted(context), context.hosted_project.id)
    assert stored.revision_id == current.revision.id
  end

  test "a stale revision is refused and stores nothing", context do
    approve!(context, :hosted)
    current = hosted_specification(context)

    {:ok, view, _html} = live(context.owner_conn, hosted_path(context))

    render_click(view, "select_pilot", %{
      "specification_id" => current.specification.id,
      "revision_id" => Ecto.UUID.generate()
    })

    assert view |> element("[data-pilot-message]") |> render() =~
             "no longer the current one for this specification"

    assert has_element?(view, "[data-no-pilot]")
    assert Repo.aggregate(RepositoryPilotSelection, :count) == 0
  end

  test "a project with no approved profile refuses the selection", context do
    current = hosted_specification(context)

    {:ok, view, _html} = live(context.owner_conn, hosted_path(context))

    render_click(view, "select_pilot", %{
      "specification_id" => current.specification.id,
      "revision_id" => current.revision.id
    })

    assert view |> element("[data-pilot-message]") |> render() =~
             "no approved execution profile yet"

    assert Repo.aggregate(RepositoryPilotSelection, :count) == 0
  end

  test "an accepted participant reads the stored pilot and cannot select", context do
    approve!(context, :hosted)
    current = hosted_specification(context)

    assert {:ok, _selection} =
             RepositoryPilots.select(hosted(context), context.hosted_project.id, %{
               specification_id: current.specification.id,
               revision_id: current.revision.id
             })

    participant = HostedAccessFixtures.hosted_identity_fixture()
    ParticipationFixtures.participant_fixture(context.hosted_project, participant.hosted_identity)

    conn = log_in_hosted(context.conn, participant.hosted_identity)
    {:ok, view, html} = live(conn, hosted_path(context))

    assert html =~ ~s(data-pilot-role="participant")
    assert html =~ ~s(data-pilot-stage="selected")
    assert field(view, "specification") =~ current.specification.id
    assert field(view, "revision-digest") =~ current.revision.content_digest
    assert has_element?(view, "[data-read-only]")
    refute has_element?(view, "[data-select-pilot]")
    refute has_element?(view, "[data-selectable-specification]")
    refute render(view) =~ "SECRET-REQUIREMENTS-BODY"

    render_click(view, "select_pilot", %{
      "specification_id" => current.specification.id,
      "revision_id" => current.revision.id
    })

    assert view |> element("[data-pilot-message]") |> render() =~
             "Only the project owner can select the pilot specification."

    assert Repo.aggregate(RepositoryPilotSelection, :count) == 1
  end

  test "the device owner selects through device-authoritative storage only", context do
    hosted_rows = Repo.aggregate(RepositoryPilotSelection, :count)
    approve!(context, :device)
    current = device_specification(context)

    {:ok, view, html} = live(context.conn, device_path(context))

    assert html =~ ~s(data-pilot-stage="select")
    assert html =~ ~s(data-pilot-role="owner")
    assert has_element?(view, ~s([data-selectable-specification="#{current.specification.id}"]))

    render_click(view, "select_pilot", %{
      "specification_id" => current.specification.id,
      "revision_id" => current.revision.id
    })

    assert render(view) =~ ~s(data-pilot-stage="selected")
    assert field(view, "revision-digest") =~ current.revision.content_digest

    assert {:ok, stored} = RepositoryPilots.current(device(context), context.device_project.id)
    assert stored.specification_id == current.specification.id
    assert Repo.aggregate(RepositoryPilotSelection, :count) == hosted_rows
  end

  test "outsiders, unknown projects, and unknown device projects fail closed", context do
    approve!(context, :hosted)
    outsider = AccountsFixtures.account_fixture()

    assert {:error, {:live_redirect, %{to: "/projects"}}} =
             context.conn |> log_in_account(outsider) |> live(hosted_path(context))

    assert {:error, {:live_redirect, %{to: "/projects"}}} =
             live(context.owner_conn, ~p"/projects/#{Ecto.UUID.generate()}/pilot")

    assert {:error, {:live_redirect, %{to: "/projects"}}} =
             live(context.conn, hosted_path(context))

    assert {:error, {:live_redirect, %{to: "/onboarding/local"}}} =
             live(context.conn, ~p"/local/projects/#{Ecto.UUID.generate()}/pilot")

    assert Repo.aggregate(RepositoryPilotSelection, :count) == 0
  end

  test "a project with no specification offers nothing to pilot", context do
    approve!(context, :hosted)

    {:ok, view, html} = live(context.owner_conn, hosted_path(context))

    assert html =~ ~s(data-pilot-stage="unavailable")
    assert has_element?(view, "[data-pilot-unavailable]")
    assert has_element?(view, "[data-no-pilot]")
    refute has_element?(view, "[data-select-pilot]")
  end

  ## Screen helpers

  defp hosted_path(context), do: ~p"/projects/#{context.hosted_project.id}/pilot"
  defp device_path(context), do: ~p"/local/projects/#{context.device_project.id}/pilot"

  defp field(view, name), do: view |> element(~s([data-pilot-field="#{name}"])) |> render()

  defp log_in_hosted(conn, hosted_identity) do
    {:ok, _session, cookie} = Sessions.create(hosted_identity, %{})

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(SessionCookie.session_key(), cookie.value)
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
