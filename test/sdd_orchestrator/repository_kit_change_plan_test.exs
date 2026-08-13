defmodule SddOrchestrator.RepositoryKitChangePlanTest do
  @moduledoc """
  Focused proof for Task 2: the worker-local `RepositoryKitChangePlan`.

  Covers the eligibility read, the base-commit staleness gate, every
  create/omit/conflict classification outcome against a real throwaway git
  repository (never mocked), the derived `safety_blocked`/
  `has_ordinary_conflicts` summary flags, expiry, and that planning performs
  no repository write of any kind.
  """

  use SddOrchestrator.DataCase, async: true

  import SddOrchestrator.RepositoryKitFixtures

  alias SddOrchestrator.Delivery.Features
  alias SddOrchestrator.RepositoryKits
  alias SddOrchestrator.RepositoryKits.RepositoryKitChangePlan

  alias SddOrchestrator.RepositoryAssessments
  alias SddOrchestrator.RepositoryPilots

  alias SddOrchestrator.RepositoryAssessments.{
    AssessmentStore,
    RepositoryAssessment,
    RepositoryAssessmentCacheProvenance,
    RepositoryAssessmentResult,
    RepositoryBindingPreparation,
    RepositoryExecutionProfileProposalPayload,
    WorkerRepositoryExecutionProfileProposalEnvelope
  }

  alias SddOrchestrator.{AccountsFixtures, ProjectsFixtures, SpecificationFixtures}

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

  setup do
    account = AccountsFixtures.account_fixture()
    workspace = ProjectsFixtures.workspace_fixture(account)
    project = ProjectsFixtures.registered_project(workspace, name: "Kit change plan project")
    repository = git_repository_fixture()

    %{
      account: account,
      workspace: workspace,
      project: project,
      repository: repository,
      now: DateTime.utc_now() |> DateTime.truncate(:second)
    }
  end

  describe "eligible_for_kit_offer?/2" do
    test "false when the pilot specification has no linked feature", context do
      refute RepositoryKits.eligible_for_kit_offer?(context.project.id, Ecto.UUID.generate())
    end

    test "false when the linked feature has not reached Ready for review or Done", context do
      current = hosted_specification!(context)
      feature = link_feature!(context, current.specification.id, "in_development")

      refute RepositoryKits.eligible_for_kit_offer?(context.project.id, feature.specification_id)
    end

    test "true once the linked feature reaches Ready for review", context do
      current = hosted_specification!(context)
      feature = link_feature!(context, current.specification.id, "ready_for_review")

      assert RepositoryKits.eligible_for_kit_offer?(context.project.id, feature.specification_id)
    end

    test "true once the linked feature reaches Done", context do
      current = hosted_specification!(context)
      feature = link_feature!(context, current.specification.id, "done")

      assert RepositoryKits.eligible_for_kit_offer?(context.project.id, feature.specification_id)
    end
  end

  describe "plan_change/4 refusals" do
    test "refuses when the pilot is not yet eligible", context do
      profile = approve!(context, context.repository.commit, @instruction_findings)
      {_selection, current} = select_pilot!(context, profile)
      link_feature!(context, current.specification.id, "in_development")

      package = publish_kit_package_fixture()

      assert {:error, :not_yet_eligible} =
               RepositoryKits.plan_change(hosted(context), context.project.id, package.id,
                 repository_path: context.repository.path
               )
    end

    test "refuses without opts[:repository_path]", context do
      profile = approve!(context, context.repository.commit, @instruction_findings)
      {_selection, current} = select_pilot!(context, profile)
      link_feature!(context, current.specification.id, "ready_for_review")

      package = publish_kit_package_fixture()

      assert {:error, :repository_path_required} =
               RepositoryKits.plan_change(hosted(context), context.project.id, package.id)
    end

    test "refuses with a stale base commit when the live repository has moved on", context do
      profile = approve!(context, context.repository.commit, @instruction_findings)
      {_selection, current} = select_pilot!(context, profile)
      link_feature!(context, current.specification.id, "ready_for_review")

      package = publish_kit_package_fixture()

      write!(context.repository.path, "drift.md", "moved on\n")
      git!(context.repository.path, ["add", "."])
      git!(context.repository.path, ["commit", "-q", "-m", "drift"])

      assert {:error, :stale_commit} =
               RepositoryKits.plan_change(hosted(context), context.project.id, package.id,
                 repository_path: context.repository.path
               )
    end

    test "propagates ManagedRuntimeProfile.build/3's own refusal when no profile is approved",
         context do
      package = publish_kit_package_fixture()

      assert {:error, :no_approved_profile} =
               RepositoryKits.plan_change(hosted(context), context.project.id, package.id,
                 repository_path: context.repository.path
               )
    end

    test "not_found for an unknown package once the pilot is eligible", context do
      profile = approve!(context, context.repository.commit, @instruction_findings)
      {_selection, current} = select_pilot!(context, profile)
      link_feature!(context, current.specification.id, "ready_for_review")

      assert {:error, :not_found} =
               RepositoryKits.plan_change(
                 hosted(context),
                 context.project.id,
                 Ecto.UUID.generate(),
                 repository_path: context.repository.path
               )
    end
  end

  describe "plan_change/4 classification" do
    test "classifies create, no-op create, protected omit, ordinary conflict, and safety conflict",
         context do
      profile = approve!(context, context.repository.commit, @instruction_findings)
      {_selection, current} = select_pilot!(context, profile)
      link_feature!(context, current.specification.id, "ready_for_review")

      package =
        publish_kit_package_fixture(%{}, [
          # Protected: AGENTS.md is in instruction_precedence, so it is
          # always "omit" even though its proposed content differs from the
          # repository's existing AGENTS.md.
          %{
            path: "AGENTS.md",
            content: "# Kit-proposed instructions, different from the repository's\n",
            executable: false
          },
          # No-op: identical to the repository's existing README.md.
          %{path: "README.md", content: readme_content(), executable: false},
          # Ordinary conflict: exists with different content, ordinary path.
          %{path: "Makefile", content: "test:\n\t@echo proposed\n", executable: false},
          # Safety conflict: exists at a secret-shaped path.
          %{path: ".env", content: "SECRET=kit-proposed\n", executable: false},
          # Plain create: absent from the repository.
          %{path: "NEW_FILE.md", content: "# New\n", executable: false}
        ])

      status_before = git!(context.repository.path, ["status", "--porcelain"])
      head_before = git!(context.repository.path, ["rev-parse", "HEAD"])
      branches_before = git!(context.repository.path, ["branch", "--list"])

      assert {:ok, plan} =
               RepositoryKits.plan_change(hosted(context), context.project.id, package.id,
                 repository_path: context.repository.path
               )

      assert %RepositoryKitChangePlan{} = plan
      assert plan.project_id == context.project.id
      assert plan.package_id == package.id
      assert plan.package_digest == package.digest
      assert plan.profile_version == profile.version
      assert plan.base_commit == context.repository.commit
      assert plan.safety_blocked == true
      assert plan.has_ordinary_conflicts == true

      operations = Map.new(plan.operations, &{&1["path"], &1})

      assert operations["AGENTS.md"]["kind"] == "omit"
      assert operations["AGENTS.md"]["conflict_severity"] == nil

      assert operations["README.md"]["kind"] == "create"
      assert operations["README.md"]["conflict_severity"] == nil

      assert operations["README.md"]["existing_sha256"] ==
               operations["README.md"]["proposed_sha256"]

      assert operations["Makefile"]["kind"] == "conflict"
      assert operations["Makefile"]["conflict_severity"] == "ordinary"
      assert is_binary(operations["Makefile"]["existing_sha256"])

      assert operations["Makefile"]["existing_sha256"] !=
               operations["Makefile"]["proposed_sha256"]

      assert operations[".env"]["kind"] == "conflict"
      assert operations[".env"]["conflict_severity"] == "safety"
      # Existing secret content is deliberately never read.
      assert operations[".env"]["existing_sha256"] == nil

      assert operations["NEW_FILE.md"]["kind"] == "create"
      assert operations["NEW_FILE.md"]["conflict_severity"] == nil
      assert operations["NEW_FILE.md"]["existing_sha256"] == nil

      # No repository write of any kind: the working tree, HEAD, and branch
      # list are byte-for-byte identical to before planning ran.
      assert git!(context.repository.path, ["status", "--porcelain"]) == status_before
      assert git!(context.repository.path, ["rev-parse", "HEAD"]) == head_before
      assert git!(context.repository.path, ["branch", "--list"]) == branches_before
    end

    test "a plan with only compatible creates and omits blocks neither safety nor ordinary flags",
         context do
      profile = approve!(context, context.repository.commit, @instruction_findings)
      {_selection, current} = select_pilot!(context, profile)
      link_feature!(context, current.specification.id, "done")

      package =
        publish_kit_package_fixture(%{}, [
          %{path: "AGENTS.md", content: "# Kit instructions\n", executable: false},
          %{path: "README.md", content: readme_content(), executable: false},
          %{path: "NEW_FILE.md", content: "# New\n", executable: false}
        ])

      assert {:ok, plan} =
               RepositoryKits.plan_change(hosted(context), context.project.id, package.id,
                 repository_path: context.repository.path
               )

      assert plan.safety_blocked == false
      assert plan.has_ordinary_conflicts == false
    end

    test "target_branch is deterministic for the same package identity", context do
      profile = approve!(context, context.repository.commit, @instruction_findings)
      {_selection, current} = select_pilot!(context, profile)
      link_feature!(context, current.specification.id, "ready_for_review")

      package =
        publish_kit_package_fixture(%{}, [%{path: "NEW_FILE.md", content: "x", executable: false}])

      assert {:ok, plan} =
               RepositoryKits.plan_change(hosted(context), context.project.id, package.id,
                 repository_path: context.repository.path
               )

      assert plan.target_branch =~ ~r{\Asdd-kit/[a-z0-9._-]+\z}
      assert plan.target_branch =~ package.version
    end
  end

  describe "plan_change/4 persistence boundary" do
    # `plan_change/4`'s own `persist_plan/6` refuses any non-`{:hosted, _}`
    # authority (including `{:device, _}`) with `{:error, :unsupported_authority}`
    # — see the moduledoc on `RepositoryKitChangePlan` for why persistence is
    # hosted-only for now. That refusal is exercised indirectly here: a
    # `{:participant, ...}` authority is already refused further upstream, by
    # `ManagedRuntimeProfile.build/3`'s own authority pattern match, with the
    # exact same `:unsupported_authority` reason, proving `plan_change/4`
    # propagates an unsupported authority without crashing. Exercising the
    # device-specific branch of `persist_plan/6` end-to-end through the public
    # API would additionally require a working device-authoritative path from
    # `Delivery.Features` (device projects have no row in the hosted
    # `Participation` boundary `Features.create/3` and `link_specification/5`
    # authorize against), which is out of this task's scope.
    test "refuses an authority ManagedRuntimeProfile.build/3 itself does not support", context do
      profile = approve!(context, context.repository.commit, @instruction_findings)
      {_selection, current} = select_pilot!(context, profile)
      link_feature!(context, current.specification.id, "ready_for_review")

      package =
        publish_kit_package_fixture(%{}, [%{path: "NEW_FILE.md", content: "x", executable: false}])

      assert {:error, :unsupported_authority} =
               RepositoryKits.plan_change(
                 {:participant, context.account.id, Ecto.UUID.generate()},
                 context.project.id,
                 package.id,
                 repository_path: context.repository.path
               )
    end
  end

  describe "current_plan/3" do
    test "returns not_found before any plan is built", context do
      assert {:error, :not_found} =
               RepositoryKits.current_plan(hosted(context), context.project.id)
    end

    test "returns the most recently built plan for the owning hosted account", context do
      profile = approve!(context, context.repository.commit, @instruction_findings)
      {_selection, current} = select_pilot!(context, profile)
      link_feature!(context, current.specification.id, "ready_for_review")

      package =
        publish_kit_package_fixture(%{}, [%{path: "NEW_FILE.md", content: "x", executable: false}])

      assert {:ok, plan} =
               RepositoryKits.plan_change(hosted(context), context.project.id, package.id,
                 repository_path: context.repository.path
               )

      assert {:ok, ^plan} = RepositoryKits.current_plan(hosted(context), context.project.id)
    end

    test "returns not_found for an unrelated hosted account", context do
      profile = approve!(context, context.repository.commit, @instruction_findings)
      {_selection, current} = select_pilot!(context, profile)
      link_feature!(context, current.specification.id, "ready_for_review")

      package =
        publish_kit_package_fixture(%{}, [%{path: "NEW_FILE.md", content: "x", executable: false}])

      assert {:ok, _plan} =
               RepositoryKits.plan_change(hosted(context), context.project.id, package.id,
                 repository_path: context.repository.path
               )

      other_account = AccountsFixtures.account_fixture()

      assert {:error, :not_found} =
               RepositoryKits.current_plan({:hosted, other_account.id}, context.project.id)
    end

    test "an expired plan is not the current plan", context do
      profile = approve!(context, context.repository.commit, @instruction_findings)
      {_selection, current} = select_pilot!(context, profile)
      link_feature!(context, current.specification.id, "ready_for_review")

      package =
        publish_kit_package_fixture(%{}, [%{path: "NEW_FILE.md", content: "x", executable: false}])

      assert {:ok, _plan} =
               RepositoryKits.plan_change(hosted(context), context.project.id, package.id,
                 repository_path: context.repository.path,
                 now: DateTime.add(context.now, -3600, :second)
               )

      assert {:error, :not_found} =
               RepositoryKits.current_plan(hosted(context), context.project.id)
    end
  end

  ## Feature and eligibility fixtures

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

  defp transition_path("draft"), do: []
  defp transition_path("ready_for_development"), do: ~w(ready_for_development)
  defp transition_path("in_development"), do: ~w(ready_for_development in_development)

  defp transition_path("ready_for_review"),
    do: ~w(ready_for_development in_development ready_for_review)

  defp transition_path("done"),
    do: ~w(ready_for_development in_development ready_for_review done)

  ## Pilot fixtures

  defp hosted_specification!(context) do
    SpecificationFixtures.hosted_specification(context.workspace, context.project,
      title: "Pilot specification #{System.unique_integer([:positive])}"
    )
  end

  defp select_pilot!(context, _profile) do
    current = hosted_specification!(context)

    assert {:ok, selection} =
             RepositoryPilots.select(hosted(context), context.project.id, %{
               specification_id: current.specification.id,
               revision_id: current.revision.id
             })

    {selection, current}
  end

  ## Assessment and profile fixtures (adapted from ManagedRuntimeProfileTest's
  ## hosted fixture chain, bound to a real throwaway git commit instead of an
  ## arbitrary fixed sha, since Task 2 compares against a real repository)

  defp approve!(context, commit, findings) do
    completed = complete!(context, commit, findings)

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

  defp complete!(context, commit, findings) do
    pending = put_pending!(context, commit, context.now)
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
      findings: findings,
      structure: [],
      stats: %{
        discovered_paths: length(findings),
        inspected_files: length(findings),
        bytes_read: Enum.reduce(findings, 0, &(&1.bytes + &2))
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

  defp put_pending!(context, commit, now) do
    assert {:ok, preparation} =
             RepositoryBindingPreparation.new(%{
               project_id: context.project.id,
               repository_provider: context.project.repository_provider,
               repository_id: context.project.canonical_repository_id,
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
    assert {:ok, stored} = AssessmentStore.put(hosted(context), pending)
    stored
  end

  defp hosted(context), do: {:hosted, context.account.id}

  ## Kit package fixture

  defp readme_content, do: "# Example project\n"

  defp publish_kit_package_fixture(attrs_overrides \\ %{}, files_overrides \\ nil) do
    files =
      files_overrides ||
        [
          %{path: "AGENTS.md", content: "# Kit instructions\n", executable: false},
          %{path: "README.md", content: readme_content(), executable: false}
        ]

    publish_package_fixture(Map.merge(%{scripts: []}, attrs_overrides), files)
  end

  ## Throwaway git repository fixture

  defp git_repository_fixture do
    base =
      Path.join(
        System.tmp_dir!(),
        "repository-kit-change-plan-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(base)

    git!(base, ["init", "-q"])
    git!(base, ["config", "user.email", "task2@example.invalid"])
    git!(base, ["config", "user.name", "Task 2"])

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
