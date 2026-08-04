defmodule SddOrchestratorWeb.RepositoryExecutionProfileLiveTest do
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

  alias SddOrchestrator.RepositoryAssessments.{
    AssessmentStore,
    ProfileStore,
    RepositoryAssessment,
    RepositoryAssessmentCacheProvenance,
    RepositoryAssessmentResult,
    RepositoryBindingPreparation,
    RepositoryExecutionProfile,
    RepositoryExecutionProfileProposalEnvelope,
    RepositoryExecutionProfileProposalPayload,
    WorkerRepositoryExecutionProfileProposalEnvelope
  }

  @scanner_digest String.duplicate("a", 64)
  @disclosure_digest String.duplicate("b", 64)
  @commit String.duplicate("1", 40)

  # The reviewable shape a worker can actually produce: commands and required
  # checks were found, no repository instruction was, and the evidence was
  # ambiguous.
  @hosted_fields %{
    commands: ["make check", "mix test"],
    required_checks: ["mix test"],
    allowed_scope: [".", "lib"],
    gaps: ["missing_repository_instructions"],
    conflicts: ["ambiguous_command_evidence"],
    multi_root_blockers: []
  }

  @hosted_findings [
    %{
      category: "check",
      path: "Makefile",
      bytes: 10,
      sha256: String.duplicate("c", 64),
      line_count: 2
    }
  ]

  # The complementary shape: an existing instruction file, so precedence is
  # visible and no gap or conflict is reported.
  @device_fields %{
    commands: ["mix test"],
    required_checks: ["mix test"],
    allowed_scope: ["."],
    gaps: [],
    conflicts: [],
    multi_root_blockers: []
  }

  @device_findings [
    %{
      category: "instruction",
      path: "AGENTS.md",
      bytes: 12,
      sha256: String.duplicate("d", 64),
      line_count: 3
    }
  ]

  setup %{conn: conn} do
    store_path =
      Path.join(
        System.tmp_dir!(),
        "repository-execution-profile-live-#{System.unique_integer([:positive])}/store.dets"
      )

    start_supervised!({Local, path: store_path})
    on_exit(fn -> File.rm_rf!(Path.dirname(store_path)) end)

    %{conn: owner_conn, account: account} = register_and_log_in_account(%{conn: conn})
    workspace = ProjectsFixtures.workspace_fixture(account)
    hosted_project = ProjectsFixtures.registered_project(workspace, name: "Hosted profile")

    {:ok, device_workspace} = Devices.establish_workspace()

    {:ok, device_project} =
      Devices.register_project(%{
        name: "Device profile",
        repository_fingerprint: ProjectsFixtures.local_repository_metadata().fingerprint,
        status: "connected"
      })

    %{
      account: account,
      device_project: device_project,
      device_workspace: device_workspace,
      hosted_project: hosted_project,
      now: DateTime.utc_now() |> DateTime.truncate(:second),
      owner_conn: owner_conn
    }
  end

  test "the hosted owner reviews the complete assessment-bound proposal before approving",
       context do
    completed = complete!(context, :hosted)
    {:ok, view, html} = live(context.owner_conn, hosted_path(context))

    assert html =~ ~s(data-screen="repository-execution-profile")
    assert html =~ ~s(data-profile-stage="review")
    assert html =~ ~s(data-profile-role="owner")

    runtime = view |> element("[data-managed-runtime-only]") |> render()
    assert runtime =~ "governs Orchestrator-managed runs only"
    assert runtime =~ "changes no repository file, instruction, CI rule, or branch policy"
    assert runtime =~ "Existing repository instructions stay authoritative"

    assert field(view, "repository") =~ "octo/example"
    assert field(view, "root") =~ "."
    assert byte_size(completed.commit) == 40
    assert field(view, "base-revision") =~ completed.commit
    assert field(view, "cache-source") =~ "Freshly scanned"
    assert field(view, "cache-stored") =~ "Yes"
    assert field(view, "cache-key-digest") =~ completed.cache_key_sha256
    assert field(view, "evidence-digest") =~ completed.evidence_sha256

    assert has_element?(view, "[data-instruction-precedence] [data-precedence-empty]")
    assert precedence(view) =~ "remain authoritative"

    assert item?(view, "commands", "make check")
    assert item?(view, "commands", "mix test")
    assert item?(view, "required-checks", "mix test")
    assert item?(view, "allowed-scope", "lib")
    assert item?(view, "gaps", "missing_repository_instructions")
    assert item?(view, "conflicts", "ambiguous_command_evidence")

    assert has_element?(
             view,
             ~s([data-proposal-field="multi-root-blockers"] [data-proposal-empty])
           )

    assert has_element?(view, "#profile-decision-form [data-approve-profile]")
    assert has_element?(view, "#profile-decision-form [data-reject-profile]")
    refute has_element?(view, "[data-read-only]")
    assert has_element?(view, "[data-no-profile-versions]")
    assert ProfileStore.count(hosted(context), context.hosted_project.id) == 0

    # No decision input may carry a proposal field.
    refute render(view) =~ "<input"
    refute render(view) =~ "<select"
  end

  test "approving appends one immutable version copied from the verified envelope", context do
    completed = complete!(context, :hosted)
    {:ok, view, _html} = live(context.owner_conn, hosted_path(context))

    render_click(view, "approve_profile", %{})

    assert render(view) =~ ~s(data-profile-stage="decided")
    assert view |> element("[data-profile-message]") |> render() =~ "Approved profile version 1"
    assert has_element?(view, ~s([data-profile-versions] [data-profile-version="1"]))
    refute has_element?(view, "[data-approve-profile]")

    assert [profile] = ProfileStore.list(hosted(context), context.hosted_project.id)
    assert profile.version == 1
    assert profile.assessment_id == completed.id
    assert profile.base_revision == completed.commit
    assert envelope_fields(completed) == Map.take(profile, Map.keys(@hosted_fields))
    assert ProfileStore.count(hosted(context), context.hosted_project.id) == 1
  end

  test "a decision that carries replacement proposal fields stores the envelope's values instead",
       context do
    completed = complete!(context, :hosted)
    {:ok, view, _html} = live(context.owner_conn, hosted_path(context))

    render_click(view, "approve_profile", %{
      "commands" => ["rm -rf ."],
      "required_checks" => ["rm -rf ."],
      "allowed_scope" => ["/etc"],
      "gaps" => [],
      "conflicts" => [],
      "multi_root_blockers" => ["/etc"],
      "root" => "/etc",
      "base_revision" => String.duplicate("e", 40)
    })

    assert [profile] = ProfileStore.list(hosted(context), context.hosted_project.id)
    assert envelope_fields(completed) == Map.take(profile, Map.keys(@hosted_fields))
    assert profile.root == completed.root
    assert profile.base_revision == completed.commit
    refute "rm -rf ." in profile.commands
    refute "/etc" in profile.allowed_scope
  end

  test "rejecting creates no version and leaves the repository unchanged", context do
    complete!(context, :hosted)
    {:ok, view, _html} = live(context.owner_conn, hosted_path(context))

    render_click(view, "reject_profile", %{})

    assert view |> element("[data-profile-message]") |> render() =~ "Proposal rejected"
    assert render(view) =~ "No profile version was created and the repository is unchanged"
    assert ProfileStore.count(hosted(context), context.hosted_project.id) == 0
    assert has_element?(view, "[data-no-profile-versions]")
    refute has_element?(view, "[data-approve-profile]")
  end

  test "a newer assessment makes the proposal unapprovable and appends nothing", context do
    complete!(context, :hosted)
    {:ok, view, _html} = live(context.owner_conn, hosted_path(context))
    assert has_element?(view, "[data-approve-profile]")

    put_pending!(context, :hosted, DateTime.add(context.now, 60, :second))

    render_click(view, "approve_profile", %{})

    assert view |> element("[data-profile-message]") |> render() =~
             "no longer the current one for this repository"

    assert has_element?(view, "[data-profile-unavailable]")
    refute has_element?(view, "[data-approve-profile]")
    assert ProfileStore.count(hosted(context), context.hosted_project.id) == 0

    {:ok, reloaded, html} = live(context.owner_conn, hosted_path(context))
    assert html =~ ~s(data-profile-stage="unavailable")
    assert has_element?(reloaded, "[data-profile-unavailable]")
    assert render(reloaded) =~ "Run a new assessment"
    render_click(reloaded, "approve_profile", %{})
    assert ProfileStore.count(hosted(context), context.hosted_project.id) == 0
  end

  test "an accepted participant reviews read-only and cannot decide", context do
    completed = complete!(context, :hosted)
    participant = HostedAccessFixtures.hosted_identity_fixture()
    ParticipationFixtures.participant_fixture(context.hosted_project, participant.hosted_identity)

    conn = log_in_hosted(context.conn, participant.hosted_identity)
    {:ok, view, html} = live(conn, hosted_path(context))

    assert html =~ ~s(data-profile-role="participant")
    assert field(view, "base-revision") =~ completed.commit
    assert field(view, "cache-key-digest") =~ completed.cache_key_sha256
    assert item?(view, "commands", "mix test")
    assert item?(view, "gaps", "missing_repository_instructions")
    assert has_element?(view, "[data-read-only]")
    refute has_element?(view, "[data-approve-profile]")
    refute has_element?(view, "#profile-decision-form")

    render_click(view, "approve_profile", %{})

    assert view |> element("[data-profile-message]") |> render() =~
             "Only the project owner can approve or reject this proposal."

    assert ProfileStore.count(hosted(context), context.hosted_project.id) == 0
    assert Repo.aggregate(RepositoryExecutionProfile, :count) == 0
  end

  test "outsiders, unknown projects, and unknown device projects fail closed", context do
    complete!(context, :hosted)
    outsider = AccountsFixtures.account_fixture()

    assert {:error, {:live_redirect, %{to: "/projects"}}} =
             context.conn |> log_in_account(outsider) |> live(hosted_path(context))

    assert {:error, {:live_redirect, %{to: "/projects"}}} =
             live(context.owner_conn, ~p"/projects/#{Ecto.UUID.generate()}/profile")

    assert {:error, {:live_redirect, %{to: "/projects"}}} =
             live(context.conn, hosted_path(context))

    assert {:error, {:live_redirect, %{to: "/onboarding/local"}}} =
             live(context.conn, ~p"/local/projects/#{Ecto.UUID.generate()}/profile")

    assert ProfileStore.count(hosted(context), context.hosted_project.id) == 0
  end

  test "the device owner approves through device-authoritative storage only", context do
    hosted_profiles = Repo.aggregate(RepositoryExecutionProfile, :count)
    completed = complete!(context, :device)

    {:ok, view, html} = live(context.conn, device_path(context))

    assert html =~ ~s(data-profile-stage="review")
    assert field(view, "repository") =~ "Local repository for Device profile"
    assert field(view, "cache-source") =~ "Freshly scanned"
    assert field(view, "evidence-digest") =~ completed.evidence_sha256

    assert has_element?(view, "[data-precedence-entry]", "Agent instructions")
    assert has_element?(view, "[data-precedence-entry]", "AGENTS.md")
    refute has_element?(view, "[data-precedence-empty]")
    assert has_element?(view, ~s([data-proposal-field="gaps"] [data-proposal-empty]))
    assert has_element?(view, ~s([data-proposal-field="conflicts"] [data-proposal-empty]))

    render_click(view, "approve_profile", %{})

    assert has_element?(view, ~s([data-profile-version="1"]))
    assert [profile] = ProfileStore.list(device(context), context.device_project.id)
    assert profile.commands == @device_fields.commands

    assert profile.instruction_precedence == [
             %{"authority" => "repository", "category" => "instruction", "path" => "AGENTS.md"}
           ]

    assert Repo.aggregate(RepositoryExecutionProfile, :count) == hosted_profiles
  end

  test "a completion without a verifiable envelope offers no approval", context do
    completed = complete!(context, :hosted)

    # Stored envelopes are immutable, so a corrupted one is reproduced the only
    # way it could exist: as a replaced row whose proposal fields no longer
    # rebuild from this assessment.
    stored = Repo.get_by!(RepositoryExecutionProfileProposalEnvelope, assessment_id: completed.id)
    assert {1, _rows} = Repo.delete_all(RepositoryExecutionProfileProposalEnvelope)

    assert {:ok, _replaced} =
             %{stored | id: Ecto.UUID.generate(), commands: ["make check", "make deploy"]}
             |> RepositoryExecutionProfileProposalEnvelope.create_changeset()
             |> Repo.insert()

    {:ok, view, html} = live(context.owner_conn, hosted_path(context))
    assert html =~ ~s(data-profile-stage="unavailable")
    assert has_element?(view, "[data-profile-unavailable]")
    refute has_element?(view, "[data-approve-profile]")
    assert render(view) =~ "verifiable minimized proposal envelope"
    assert render(view) =~ "Run a new assessment"
    refute render(view) =~ "invalid_proposal_envelope"

    assert {1, _rows} = Repo.delete_all(RepositoryExecutionProfileProposalEnvelope)

    {:ok, legacy, legacy_html} = live(context.owner_conn, hosted_path(context))
    assert legacy_html =~ ~s(data-profile-stage="unavailable")
    assert has_element?(legacy, "[data-profile-unavailable]")

    render_click(legacy, "approve_profile", %{})
    assert ProfileStore.count(hosted(context), context.hosted_project.id) == 0
  end

  ## Screen helpers

  defp hosted_path(context), do: ~p"/projects/#{context.hosted_project.id}/profile"
  defp device_path(context), do: ~p"/local/projects/#{context.device_project.id}/profile"

  defp field(view, name), do: view |> element(~s([data-profile-field="#{name}"])) |> render()
  defp precedence(view), do: view |> element("[data-instruction-precedence]") |> render()

  defp item?(view, section, text),
    do: has_element?(view, ~s([data-proposal-field="#{section}"] [data-proposal-item]), text)

  ## Domain fixtures

  defp complete!(context, kind) do
    pending = put_pending!(context, kind, context.now)
    command = command!(pending)
    result = completed_result!(command, findings(kind))
    delivered = worker_envelope!(command, result, fields(kind))

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

  defp completed_result!(command, findings) do
    assert {:ok, result} =
             RepositoryAssessmentResult.completed(command, completed_scan(command, findings))

    result
  end

  defp completed_scan(command, findings) do
    %{
      protocol_version: command.version,
      assessment_id: command.assessment_id,
      project_id: command.project_id,
      repository: %{provider: command.repository_provider, id: command.repository_id},
      root: command.root,
      commit: command.commit,
      scanner_contract_digest: command.scanner_contract_digest,
      status: "completed",
      findings: findings,
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

  defp envelope_fields(completed) do
    envelope =
      Repo.get_by!(RepositoryExecutionProfileProposalEnvelope, assessment_id: completed.id)

    RepositoryExecutionProfileProposalEnvelope.proposal_fields(envelope)
  end

  defp fields(:hosted), do: @hosted_fields
  defp fields(:device), do: @device_fields

  defp findings(:hosted), do: @hosted_findings
  defp findings(:device), do: @device_findings

  defp authority(context, :hosted), do: hosted(context)
  defp authority(context, :device), do: device(context)

  defp hosted(context), do: {:hosted, context.account.id}
  defp device(context), do: {:device, context.device_workspace}

  defp log_in_hosted(conn, hosted_identity) do
    {:ok, _session, cookie} = Sessions.create(hosted_identity, %{})

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(SessionCookie.session_key(), cookie.value)
  end
end
