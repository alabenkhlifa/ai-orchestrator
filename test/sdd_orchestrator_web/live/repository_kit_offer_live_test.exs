defmodule SddOrchestratorWeb.RepositoryKitOfferLiveTest do
  @moduledoc """
  Focused proof for Task 3: the post-pilot eligibility, decline, and
  reviewable-diff LiveView.

  Mirrors `RepositoryPilotLiveTest`'s hosted-owner/hosted-participant setup
  conventions and `RepositoryKitChangePlanTest`'s real-pilot,
  real-throwaway-git-repository fixture chain, since this screen renders
  Task 2's exact plan rather than recomputing anything itself.
  """
  use SddOrchestratorWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import SddOrchestrator.RepositoryKitFixtures

  alias SddOrchestrator.Delivery.Features
  alias SddOrchestrator.HostedAccess.{SessionCookie, Sessions}
  alias SddOrchestrator.HostedAccessFixtures
  alias SddOrchestrator.ParticipationFixtures
  alias SddOrchestrator.ProjectsFixtures
  alias SddOrchestrator.Repo
  alias SddOrchestrator.RepositoryAssessments
  alias SddOrchestrator.RepositoryKits
  alias SddOrchestrator.RepositoryKits.{RepositoryKitChangePlan, RepositoryKitInstallation}
  alias SddOrchestrator.RepositoryPilots
  alias SddOrchestrator.SpecificationFixtures

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

  @instruction_findings [
    %{
      category: "instruction",
      path: "AGENTS.md",
      bytes: 40,
      sha256: String.duplicate("d", 64),
      line_count: 3
    }
  ]

  setup %{conn: conn} do
    %{conn: owner_conn, account: account} = register_and_log_in_account(%{conn: conn})
    workspace = ProjectsFixtures.workspace_fixture(account)
    project = ProjectsFixtures.registered_project(workspace, name: "Kit offer project")
    repository = git_repository_fixture()

    %{
      account: account,
      conn: conn,
      owner_conn: owner_conn,
      project: project,
      repository: repository,
      workspace: workspace,
      now: DateTime.utc_now() |> DateTime.truncate(:second)
    }
  end

  test "no pilot selected is not-yet-eligible", context do
    {:ok, view, html} = live(context.owner_conn, kit_path(context))

    assert html =~ ~s(data-screen="repository-kit-offer")
    assert html =~ ~s(data-kit-stage="not_yet_eligible")
    assert html =~ ~s(data-kit-role="owner")
    assert has_element?(view, "[data-kit-not-yet-eligible]")
    refute has_element?(view, "[data-build-plan]")
    refute has_element?(view, "[data-decline-offer]")
  end

  test "a pilot present but short of ready_for_review/done is not-yet-eligible", context do
    approve!(context)
    current = hosted_specification!(context)
    select_pilot!(context, current)
    link_feature!(context, current.specification.id, "in_development")

    {:ok, view, html} = live(context.owner_conn, kit_path(context))

    assert html =~ ~s(data-kit-stage="not_yet_eligible")
    assert has_element?(view, "[data-kit-not-yet-eligible]")
  end

  test "an eligible pilot shows the optional offer with build and decline actions", context do
    approve!(context)
    current = hosted_specification!(context)
    select_pilot!(context, current)
    link_feature!(context, current.specification.id, "ready_for_review")
    package = publish_package!(default_kit_files())

    {:ok, view, html} = live(context.owner_conn, kit_path(context))

    assert html =~ ~s(data-kit-stage="offer")
    assert has_element?(view, "[data-build-plan]")
    assert has_element?(view, "[data-decline-offer]")
    assert view |> element("[data-kit-publisher]") |> render() =~ package.publisher
    assert view |> element("[data-kit-version]") |> render() =~ package.version
  end

  test "declining is UI-only: it stores nothing and returns to a calm state", context do
    approve!(context)
    current = hosted_specification!(context)
    select_pilot!(context, current)
    link_feature!(context, current.specification.id, "done")
    publish_package!(default_kit_files())

    {:ok, view, _html} = live(context.owner_conn, kit_path(context))

    render_click(view, "decline", %{})

    assert render(view) =~ ~s(data-kit-stage="declined")
    refute has_element?(view, "[data-build-plan]")
    refute has_element?(view, "[data-decline-offer]")
    assert Repo.aggregate(RepositoryKitChangePlan, :count) == 0
  end

  test "building the plan without a resolvable worker checkout fails honestly, not silently",
       context do
    approve!(context)
    current = hosted_specification!(context)
    select_pilot!(context, current)
    link_feature!(context, current.specification.id, "ready_for_review")
    publish_package!(default_kit_files())

    {:ok, view, _html} = live(context.owner_conn, kit_path(context))

    render_click(view, "build_plan", %{})

    assert view |> element("[data-kit-message]") |> render() =~ "connected worker"
    assert render(view) =~ ~s(data-kit-stage="offer")
    assert Repo.aggregate(RepositoryKitChangePlan, :count) == 0
  end

  test "a real plan renders the create, omit, ordinary-conflict, and safety-conflict groups",
       context do
    approve!(context)
    current = hosted_specification!(context)
    select_pilot!(context, current)
    link_feature!(context, current.specification.id, "ready_for_review")

    package =
      publish_package!([
        # Protected: AGENTS.md is in instruction_precedence, so it is always
        # "omit" even though its proposed content differs from the
        # repository's existing AGENTS.md.
        %{
          path: "AGENTS.md",
          content: "# Kit-proposed instructions, different from the repository's\n",
          executable: false
        },
        # Ordinary conflict: exists with different content, ordinary path.
        %{path: "Makefile", content: "test:\n\t@echo proposed\n", executable: false},
        # Safety conflict: exists at a secret-shaped path.
        %{path: ".env", content: "SECRET=kit-proposed\n", executable: false},
        # Plain create: absent from the repository.
        %{path: "NEW_FILE.md", content: "# New\n", executable: false}
      ])

    assert {:ok, plan} =
             RepositoryKits.plan_change(hosted(context), context.project.id, package.id,
               repository_path: context.repository.path
             )

    assert plan.safety_blocked == true
    assert plan.has_ordinary_conflicts == true

    {:ok, view, html} = live(context.owner_conn, kit_path(context))

    assert html =~ ~s(data-kit-stage="plan")
    refute has_element?(view, "[data-build-plan]")

    assert has_element?(view, ~s([data-operation-group="omit"]))
    assert has_element?(view, ~s([data-operation-group="ordinary-conflict"]))
    assert has_element?(view, ~s([data-operation-group="safety-conflict"]))
    assert has_element?(view, ~s([data-operation-group="create"]))

    assert has_element?(view, ~s([data-operation-path="AGENTS.md"]))
    assert has_element?(view, ~s([data-operation-path="Makefile"]))
    assert has_element?(view, ~s([data-operation-path=".env"]))
    assert has_element?(view, ~s([data-operation-path="NEW_FILE.md"]))

    assert has_element?(view, "[data-kit-safety-blocked]")
    assert has_element?(view, "[data-kit-ordinary-blocked]")

    # Proposed content is rendered decoded, plain, and never interpreted.
    assert render(view) =~ "# New"
    refute render(view) =~ "No apply"
    refute render(view) =~ "data-apply"
  end

  test "a non-owner participant sees a read-only view with no trigger or decline action",
       context do
    approve!(context)
    current = hosted_specification!(context)
    select_pilot!(context, current)
    link_feature!(context, current.specification.id, "ready_for_review")
    publish_package!(default_kit_files())

    participant = HostedAccessFixtures.hosted_identity_fixture()
    ParticipationFixtures.participant_fixture(context.project, participant.hosted_identity)

    conn = log_in_hosted(context.conn, participant.hosted_identity)
    {:ok, view, html} = live(conn, kit_path(context))

    assert html =~ ~s(data-kit-role="participant")
    assert html =~ ~s(data-kit-stage="offer")
    assert has_element?(view, "[data-read-only]")
    refute has_element?(view, "[data-build-plan]")
    refute has_element?(view, "[data-decline-offer]")

    render_click(view, "decline", %{})
    assert render(view) =~ ~s(data-kit-stage="offer")

    render_click(view, "build_plan", %{})
    assert view |> element("[data-kit-message]") |> render() =~ "Only the project owner"
    assert Repo.aggregate(RepositoryKitChangePlan, :count) == 0
  end

  test "an outsider is denied and an unknown project redirects", context do
    outsider = SddOrchestrator.AccountsFixtures.account_fixture()

    assert {:error, {:live_redirect, %{to: "/projects"}}} =
             context.conn |> log_in_account(outsider) |> live(kit_path(context))

    assert {:error, {:live_redirect, %{to: "/projects"}}} =
             live(context.owner_conn, ~p"/projects/#{Ecto.UUID.generate()}/kit")
  end

  test "the apply action is hidden for a plan with conflicts", context do
    approve!(context)
    current = hosted_specification!(context)
    select_pilot!(context, current)
    link_feature!(context, current.specification.id, "ready_for_review")

    package = publish_package!([%{path: ".env", content: "SECRET=x\n", executable: false}])

    assert {:ok, plan} =
             RepositoryKits.plan_change(hosted(context), context.project.id, package.id,
               repository_path: context.repository.path
             )

    assert plan.safety_blocked == true

    {:ok, view, _html} = live(context.owner_conn, kit_path(context))

    refute has_element?(view, "[data-apply-plan]")
  end

  test "the apply action appears for a clean plan and honestly refuses without a resolvable worker checkout",
       context do
    approve!(context)
    current = hosted_specification!(context)
    select_pilot!(context, current)
    link_feature!(context, current.specification.id, "ready_for_review")

    package = publish_package!([%{path: "NEW_FILE.md", content: "# new\n", executable: false}])

    assert {:ok, plan} =
             RepositoryKits.plan_change(hosted(context), context.project.id, package.id,
               repository_path: context.repository.path
             )

    refute plan.safety_blocked
    refute plan.has_ordinary_conflicts

    {:ok, view, _html} = live(context.owner_conn, kit_path(context))

    assert has_element?(view, "[data-apply-plan]")

    render_click(view, "apply_plan", %{})

    assert view |> element("[data-kit-message]") |> render() =~ "connected worker"
    assert render(view) =~ ~s(data-kit-stage="plan")
    assert Repo.aggregate(RepositoryKitInstallation, :count) == 0
  end

  ## Screen helpers

  defp kit_path(context), do: ~p"/projects/#{context.project.id}/kit"

  defp log_in_hosted(conn, hosted_identity) do
    {:ok, _session, cookie} = Sessions.create(hosted_identity, %{})

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(SessionCookie.session_key(), cookie.value)
  end

  ## Feature and eligibility fixtures (adapted from RepositoryKitChangePlanTest)

  defp link_feature!(context, specification_id, lifecycle_column) do
    actor = %{account_id: context.account.id, hosted_identity_id: nil}

    assert {:ok, feature} =
             Features.create(context.project.id, actor, %{title: "Pilot feature"})

    assert {:ok, feature} =
             Features.link_specification(
               context.workspace,
               context.project.id,
               actor,
               feature,
               specification_id
             )

    Enum.reduce(transition_path(lifecycle_column), feature, fn column, feature ->
      assert {:ok, feature} = Features.transition(context.project.id, actor, feature, column)
      feature
    end)
  end

  defp transition_path("in_development"), do: ~w(ready_for_development in_development)

  defp transition_path("ready_for_review"),
    do: ~w(ready_for_development in_development ready_for_review)

  defp transition_path("done"),
    do: ~w(ready_for_development in_development ready_for_review done)

  ## Pilot and specification fixtures

  defp hosted_specification!(context) do
    SpecificationFixtures.hosted_specification(context.workspace, context.project,
      title: "Pilot specification #{System.unique_integer([:positive])}"
    )
  end

  defp select_pilot!(context, current) do
    assert {:ok, selection} =
             RepositoryPilots.select(hosted(context), context.project.id, %{
               specification_id: current.specification.id,
               revision_id: current.revision.id
             })

    selection
  end

  ## Assessment and profile fixtures (adapted from RepositoryKitChangePlanTest's
  ## hosted fixture chain, bound to a real throwaway git commit)

  defp approve!(context) do
    completed = complete!(context)

    assert {:ok, review} =
             RepositoryAssessments.profile_review(hosted(context), completed.project_id)

    assert {:ok, profile} =
             RepositoryAssessments.approve_profile(
               hosted(context),
               completed.project_id,
               review.proposal
             )

    profile
  end

  defp complete!(context) do
    pending = put_pending!(context)
    assert {:ok, command} = RepositoryAssessment.command(pending)

    scan = %{
      protocol_version: command.version,
      assessment_id: command.assessment_id,
      project_id: command.project_id,
      repository: %{provider: command.repository_provider, id: command.repository_id},
      root: command.root,
      commit: command.commit,
      scanner_contract_digest: command.scanner_contract_digest,
      status: "completed",
      findings: @instruction_findings,
      structure: [],
      stats: %{
        discovered_paths: length(@instruction_findings),
        inspected_files: length(@instruction_findings),
        bytes_read: Enum.reduce(@instruction_findings, 0, &(&1.bytes + &2))
      }
    }

    assert {:ok, result} = RepositoryAssessmentResult.completed(command, scan)

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
             RepositoryAssessments.finish_assessment(
               hosted(context),
               pending.project_id,
               command,
               result,
               provenance,
               now: context.now,
               proposal_envelope: envelope
             )

    completed
  end

  defp put_pending!(context) do
    assert {:ok, preparation} =
             RepositoryBindingPreparation.new(%{
               project_id: context.project.id,
               repository_provider: context.project.repository_provider,
               repository_id: context.project.canonical_repository_id,
               root: ".",
               commit: context.repository.commit,
               scanner_contract_digest: @scanner_digest,
               disclosure_digest: @disclosure_digest,
               worker_ref: Ecto.UUID.generate(),
               nonce: Ecto.UUID.generate(),
               issued_at: context.now,
               expires_at: DateTime.add(context.now, 120, :second)
             })

    assert {:ok, pending} = RepositoryAssessment.pending(preparation, context.now)
    assert {:ok, stored} = AssessmentStore.put(hosted(context), pending)
    stored
  end

  defp hosted(context), do: {:hosted, context.account.id}

  ## Kit package fixtures

  defp readme_content, do: "# Example project\n"

  defp default_kit_files do
    [
      %{path: "AGENTS.md", content: "# Kit instructions\n", executable: false},
      %{path: "README.md", content: readme_content(), executable: false}
    ]
  end

  defp publish_package!(files) do
    publish_package_fixture(%{scripts: []}, files)
  end

  ## Throwaway git repository fixture (adapted from RepositoryKitChangePlanTest)

  defp git_repository_fixture do
    base =
      Path.join(
        System.tmp_dir!(),
        "repository-kit-offer-live-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(base)

    git!(base, ["init", "-q"])
    git!(base, ["config", "user.email", "task3@example.invalid"])
    git!(base, ["config", "user.name", "Task 3"])

    write!(base, "AGENTS.md", "# Existing repository instructions\n\nFollow these exactly.\n")
    write!(base, "README.md", readme_content())
    write!(base, "Makefile", "test:\n\t@echo existing\n")
    write!(base, ".env", "SECRET=do-not-overwrite\n")

    git!(base, ["add", "."])
    git!(base, ["commit", "-q", "-m", "fixture"])
    commit = git!(base, ["rev-parse", "HEAD"])

    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(base) end)

    %{path: base, commit: commit}
  end

  defp write!(repository, relative_path, content) do
    path = Path.join(repository, relative_path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  defp git!(repository, args) do
    {output, 0} = System.cmd("git", ["-C", repository | args], stderr_to_stdout: true)
    String.trim(output)
  end
end
