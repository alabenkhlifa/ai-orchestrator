defmodule SddOrchestratorWeb.MacRepositoryAssessmentTest.MetadataAdapter do
  @moduledoc false
  @behaviour SddOrchestrator.RepositoryAssessments.RepositoryMetadataAdapter

  @commit "0123456789abcdef0123456789abcdef01234567"

  @doc "The commit every verified binding in this suite is anchored to."
  def commit, do: @commit

  @impl true
  def prepare(request), do: {:ok, verified(request)}

  @impl true
  def revalidate(request), do: {:ok, verified(request)}

  # Preparing and revalidating a binding reaches the owner's Mac, so the suite
  # supplies that one boundary. It answers only with the identity the authorized
  # request already carries, which keeps every decision below in the product.
  defp verified(request) do
    %{
      repository_provider: request.repository_provider,
      repository_id: request.repository_id,
      root: request.selected_root,
      commit: @commit
    }
  end
end

defmodule SddOrchestratorWeb.MacRepositoryAssessmentTest do
  @moduledoc """
  `specs/46` Task 3. Proof that the whole assessment chain works for a person
  clicking through the screens, on a hosted project whose repository is a Git
  repository on the owner's Mac.

  It owns AC-04 and AC-05:

    * AC-04 — an assessment of such a repository completes, and the owner can
      then approve its execution profile.
    * AC-05 — a GitHub project's assessment and profile approval are unchanged.

  Task 1 proved the chain at the stores and Task 2 proved the assessment
  screen's label and its unreachable-Mac state. This file covers the level
  neither reached: one journey through `RepositoryAssessmentLive` and
  `RepositoryExecutionProfileLive` at the hosted routes, ending in an approved
  profile a later read finds.

  The point of the slice is what the block cost, not the two screens, so the
  journey is followed by the readout on the feature page: the `execution_profile`
  start precondition for a feature on that project is unmet before the approval
  and met after it. A Mac project could reach no run at all before this slice.

  The device store is a singleton GenServer not started in test, and the
  repository metadata adapter is application-wide, so this case is `async:
  false`.
  """
  use SddOrchestratorWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias SddOrchestrator.Delivery.{Features, GuidedRequirements, Start}
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.DeviceStore.Local
  alias SddOrchestrator.Portability.HostedLocalRepositoryBinding
  alias SddOrchestrator.Projects
  alias SddOrchestrator.ProjectsFixtures
  alias SddOrchestrator.Repo
  alias SddOrchestrator.RepositoryAssessments
  alias SddOrchestrator.SpecificationStore

  alias SddOrchestrator.RepositoryAssessments.{
    AssessmentStore,
    BindingStore,
    RepositoryAssessment,
    RepositoryAssessmentCacheProvenance,
    RepositoryAssessmentResult,
    RepositoryExecutionProfileProposalPayload,
    WorkerRepositoryExecutionProfileProposalEnvelope
  }

  alias SddOrchestratorWeb.MacRepositoryAssessmentTest.MetadataAdapter

  # The reviewable shape a worker can actually produce for a small repository:
  # a check file was found and no repository instruction was.
  @findings [
    %{
      category: "check",
      path: "Makefile",
      bytes: 10,
      sha256: String.duplicate("c", 64),
      line_count: 2
    }
  ]

  @proposal_fields %{
    commands: ["make check", "mix test"],
    required_checks: ["mix test"],
    allowed_scope: [".", "lib"],
    gaps: ["missing_repository_instructions"],
    conflicts: [],
    multi_root_blockers: []
  }

  # One body per guided part, so a feature can be made ready and its start
  # readout rendered. What the words say is never asserted.
  @requirements %{
    "outcome" => "A person can start a run on a repository that lives on a Mac.",
    "users" => "The project owner and the participants invited to it.",
    "rules" => "Nothing starts until every precondition is met.",
    "done" => "The run begins and the feature moves to In development."
  }

  setup %{conn: conn} do
    store_path =
      Path.join(
        System.tmp_dir!(),
        "mac-repository-assessment-#{System.unique_integer([:positive])}/store.dets"
      )

    start_supervised!({Local, path: store_path})
    :ok = BindingStore.reset()

    previous_adapter = Application.get_env(:sdd_orchestrator, :repository_metadata_adapter)
    Application.put_env(:sdd_orchestrator, :repository_metadata_adapter, MetadataAdapter)

    on_exit(fn ->
      File.rm_rf!(Path.dirname(store_path))

      if previous_adapter do
        Application.put_env(:sdd_orchestrator, :repository_metadata_adapter, previous_adapter)
      else
        Application.delete_env(:sdd_orchestrator, :repository_metadata_adapter)
      end
    end)

    %{conn: owner_conn, account: account} = register_and_log_in_account(%{conn: conn})
    workspace = ProjectsFixtures.workspace_fixture(account)

    # The screen offers workers from the established device workspace, so the
    # Mac the project binds to is paired to that one and reporting in.
    {:ok, device_workspace} = Devices.establish_workspace()
    worker = ProjectsFixtures.attached_worker_fixture(device_workspace)

    %{
      account: account,
      device_workspace: device_workspace,
      owner_conn: owner_conn,
      worker: worker,
      workspace: workspace
    }
  end

  describe "a repository on the owner's Mac, from the assessment screen to an approved profile" do
    test "the owner confirms, starts, and approves, and the profile is readable after [AC-04]",
         ctx do
      project = mac_project(ctx, "Ledger On My Mac")

      # The premise: no GitHub connection, one worker binding.
      assert Repo.get_by(HostedLocalRepositoryBinding, project_id: project.id)
      assert project.repository_provider == "local"
      refute Repo.preload(project, :repository_connection).repository_connection

      view = open_assessment(ctx, project)
      assert render(view) =~ ~s(data-assessment-stage="disclosure")

      confirm_boundary(ctx, view)

      assert view |> element(~s([data-binding-field="repository"])) |> render() =~
               "Local repository for Ledger On My Mac"

      start_assessment(view)

      # The scan runs on the Mac, so its result arrives over the worker
      # boundary. It is the only step of this journey that is not a click.
      completed = complete_through_worker!(ctx, project)
      assert completed.state == "completed"
      assert completed.repository_provider == "local"
      # The stored assessment is bound to the commit the screen verified.
      assert completed.commit == MetadataAdapter.commit()

      profile_view = open_profile(ctx, project)
      assert render(profile_view) =~ ~s(data-profile-role="owner")
      approve_profile(profile_view)

      assert {:ok, approved} =
               RepositoryAssessments.approved_profile({:hosted, ctx.account.id}, project.id)

      assert approved.version == 1
      assert approved.project_id == project.id
      assert approved.assessment_id == completed.id
      assert approved.base_revision == completed.commit
      assert approved.required_checks == @proposal_fields.required_checks
    end
  end

  describe "what the approval unblocks" do
    test "the execution_profile start precondition flips from unmet to met [AC-04]", ctx do
      project = mac_project(ctx, "Ledger On My Mac")
      feature = ready_feature(ctx, project)

      refute met?(ctx, project, feature, "execution_profile")

      refute ctx.workspace
             |> Start.preconditions(owner_actor(ctx), %{project: project, feature: feature})
             |> Enum.find(&(&1.key == :execution_profile))
             |> Map.fetch!(:met?)

      assess_and_approve!(ctx, project)

      # The readout a person reads, and the check the press acts on, both flip.
      assert met?(ctx, project, feature, "execution_profile")

      assert ctx.workspace
             |> Start.preconditions(owner_actor(ctx), %{project: project, feature: feature})
             |> Enum.find(&(&1.key == :execution_profile))
             |> Map.fetch!(:met?)
    end
  end

  describe "a GitHub project is unchanged" do
    test "the same journey still names the connected repository and cannot start it [AC-05]",
         ctx do
      project = github_project(ctx, "Roadmap Alpha")

      view = open_assessment(ctx, project)

      # The connected repository keeps its own name. A GitHub project's
      # repository identity is not a portable local one, so it is named on the
      # disclosure stage's not-on-a-Mac state rather than a verified binding:
      # this screen never reaches that stage for such a project. The name must
      # never pick up the label the local binding introduced.
      repository = view |> element("[data-repository-name]") |> render()
      assert repository =~ "octo/example"
      refute repository =~ "Local repository for"

      # No confirmation is offered: no worker can match a GitHub repository id
      # to a local folder's identity.
      assert has_element?(view, "[data-repository-not-verifiable]")
      refute has_element?(view, "#assessment-binding-form")
      refute has_element?(view, "[data-confirm-boundary]")

      feature = ready_feature(ctx, project)
      refute met?(ctx, project, feature, "execution_profile")

      refute ctx.workspace
             |> Start.preconditions(owner_actor(ctx), %{project: project, feature: feature})
             |> Enum.find(&(&1.key == :execution_profile))
             |> Map.fetch!(:met?)
    end
  end

  ## The journey

  defp assess_and_approve!(ctx, project) do
    view = open_assessment(ctx, project)
    confirm_boundary(ctx, view)
    start_assessment(view)
    completed = complete_through_worker!(ctx, project)

    ctx
    |> open_profile(project)
    |> approve_profile()

    completed
  end

  defp open_assessment(ctx, project) do
    {:ok, view, html} = live(ctx.owner_conn, ~p"/projects/#{project.id}/assessment")
    assert html =~ ~s(data-screen="repository-assessment")
    view
  end

  defp confirm_boundary(ctx, view) do
    view
    |> form("#assessment-binding-form",
      assessment: %{selected_root: ".", worker_ref: ctx.worker.id, confirmed: "true"}
    )
    |> render_submit()

    render_async(view)

    assert has_element?(view, "[data-verified-binding]")
    view
  end

  defp start_assessment(view) do
    view |> form("#assessment-start-form") |> render_submit()
    assert has_element?(view, "[data-assessment-pending]")
    view
  end

  defp open_profile(ctx, project) do
    {:ok, view, html} = live(ctx.owner_conn, ~p"/projects/#{project.id}/profile")
    assert html =~ ~s(data-profile-stage="review")
    view
  end

  defp approve_profile(view) do
    render_click(view, "approve_profile", %{})
    assert has_element?(view, ~s([data-profile-versions] [data-profile-version="1"]))
    view
  end

  ## The worker boundary

  # The pending assessment the screen created, finished the way a returning scan
  # result finishes it. Nothing here decides authorization: the same stores the
  # screens use accept or refuse it.
  defp complete_through_worker!(ctx, project) do
    authority = {:hosted, ctx.account.id}

    assert {:ok, pending} = AssessmentStore.latest(authority, project.id)
    assert pending.state == RepositoryAssessment.pending_state()
    assert {:ok, command} = RepositoryAssessment.command(pending)
    assert {:ok, result} = RepositoryAssessmentResult.completed(command, scan(command))

    assert {:ok, completed} =
             RepositoryAssessments.finish_assessment(
               authority,
               project.id,
               command,
               result,
               provenance!(command, result),
               proposal_envelope: envelope!(command, result)
             )

    completed
  end

  defp scan(command) do
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

  defp envelope!(command, result) do
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

  ## Projects and features

  # A hosted project whose repository is a Git repository on the owner's Mac:
  # registration writes the worker binding that is its only link to it.
  defp mac_project(ctx, name) do
    attempt =
      ProjectsFixtures.device_attempt_ready_for_hosted(ctx.device_workspace, ctx.workspace,
        worker_id: ctx.worker.id
      )

    {:ok, project} = Projects.register_project(ctx.workspace, attempt, name: name)
    project
  end

  # The comparison case: a hosted project whose repository is connected through
  # GitHub, which is the only kind that could be assessed before this slice.
  defp github_project(ctx, name),
    do: ProjectsFixtures.registered_project(ctx.workspace, name: name)

  # One feature whose readiness is cleared, so the feature page renders the
  # start readout rather than the earlier drafting state.
  defp ready_feature(ctx, project) do
    assert {:ok, feature} = Features.create(project.id, owner_actor(ctx), %{title: "Start a run"})

    write_requirements(ctx, project, feature)

    {:ok, view, _html} = live(ctx.owner_conn, feature_path(project, feature))
    view |> element("[data-check-readiness]") |> render_click()
    view |> element("[data-make-ready]") |> render_click()

    assert {:ok, feature} = Features.fetch(project.id, owner_actor(ctx), feature.id)
    feature
  end

  # Whether one start precondition is rendered met on the feature page. The
  # readout itself is asserted present, so an absent one can never read as met.
  defp met?(ctx, project, feature, key) do
    {:ok, view, _html} = live(ctx.owner_conn, feature_path(project, feature))

    assert has_element?(view, "[data-start-preconditions]")
    assert has_element?(view, "[data-start-precondition='#{key}']")
    has_element?(view, "[data-start-precondition='#{key}'][data-precondition-met=true]")
  end

  defp feature_path(project, feature),
    do: ~p"/projects/#{project.id}/features/#{feature.id}"

  defp owner_actor(ctx), do: %{account_id: ctx.account.id, hosted_identity_id: nil}

  defp write_requirements(ctx, project, feature) do
    {:ok, current} =
      SpecificationStore.get_current(ctx.workspace, project.id, feature.specification_id)

    {:ok, appended} =
      SpecificationStore.append_revision(
        ctx.workspace,
        project.id,
        feature.specification_id,
        current.revision.id,
        %{
          revision_id: Ecto.UUID.generate(),
          documents: %{
            requirements: GuidedRequirements.render(@requirements),
            design: current.revision.design_document,
            tasks: current.revision.tasks_document
          }
        }
      )

    appended
  end
end
