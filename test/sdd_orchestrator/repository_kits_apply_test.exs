defmodule SddOrchestrator.RepositoryKitsApplyTest do
  @moduledoc """
  Focused proof for Task 4: applying one confirmed `RepositoryKitChangePlan`
  on an isolated branch.

  Covers `RepositoryKits.apply_plan/4`'s authorization, expiry, and conflict
  gates against a real, non-conflicting, persisted plan built the same way
  `RepositoryKitChangePlanTest` builds one (real throwaway git repository,
  never mocked), and exercises `WorkerKitApply.apply/5` directly for the
  defense-in-depth scenarios (default-branch, path/symlink escape,
  unexpected-file, operation allowlist, partial-failure rollback) that are
  not reachable through the normal planning flow.
  """

  use SddOrchestrator.DataCase, async: true

  import SddOrchestrator.RepositoryKitFixtures

  alias SddOrchestrator.Delivery.Features
  alias SddOrchestrator.RepositoryKits
  alias SddOrchestrator.RepositoryKits.{RepositoryKitInstallation, WorkerKitApply}

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
    project = ProjectsFixtures.registered_project(workspace, name: "Kit apply project")
    repository = git_repository_fixture()

    %{
      account: account,
      workspace: workspace,
      project: project,
      repository: repository,
      now: DateTime.utc_now() |> DateTime.truncate(:second)
    }
  end

  describe "apply_plan/4 authorization" do
    test "refuses a participant viewer without touching the repository", context do
      %{plan: plan} = build_plan!(context, default_files())
      participant_account = AccountsFixtures.account_fixture()

      branches_before = git!(context.repository.path, ["branch", "--list"])
      head_before = git!(context.repository.path, ["rev-parse", "HEAD"])

      assert {:error, :unauthorized} =
               RepositoryKits.apply_plan(
                 {:participant, participant_account.id, Ecto.UUID.generate()},
                 context.project.id,
                 plan.id,
                 repository_path: context.repository.path
               )

      assert git!(context.repository.path, ["branch", "--list"]) == branches_before
      assert git!(context.repository.path, ["rev-parse", "HEAD"]) == head_before
    end

    test "refuses a hosted account that does not own this project", context do
      %{plan: plan} = build_plan!(context, default_files())
      other_account = AccountsFixtures.account_fixture()

      assert {:error, :unauthorized} =
               RepositoryKits.apply_plan(
                 {:hosted, other_account.id},
                 context.project.id,
                 plan.id,
                 repository_path: context.repository.path
               )
    end

    test "refuses a device authority", context do
      %{plan: plan} = build_plan!(context, default_files())

      assert {:error, :unauthorized} =
               RepositoryKits.apply_plan(
                 {:device, :not_a_real_device_workspace},
                 context.project.id,
                 plan.id,
                 repository_path: context.repository.path
               )
    end
  end

  describe "apply_plan/4 stale-plan and stale-commit gates" do
    test "refuses an expired plan before touching the repository", context do
      %{plan: plan} = build_plan!(context, default_files())
      branches_before = git!(context.repository.path, ["branch", "--list"])

      assert {:error, :plan_expired} =
               RepositoryKits.apply_plan(hosted(context), context.project.id, plan.id,
                 repository_path: context.repository.path,
                 now: DateTime.add(plan.expires_at, 1, :second)
               )

      assert git!(context.repository.path, ["branch", "--list"]) == branches_before
    end

    test "refuses when the repository HEAD advanced past the plan's base commit", context do
      %{plan: plan} = build_plan!(context, default_files())

      write!(context.repository.path, "drift.md", "moved on\n")
      git!(context.repository.path, ["add", "."])
      git!(context.repository.path, ["commit", "-q", "-m", "drift"])

      branches_before = git!(context.repository.path, ["branch", "--list"])

      assert {:error, :stale_commit} =
               RepositoryKits.apply_plan(hosted(context), context.project.id, plan.id,
                 repository_path: context.repository.path
               )

      assert git!(context.repository.path, ["branch", "--list"]) == branches_before
    end
  end

  describe "apply_plan/4 conflict gate" do
    test "refuses a plan with unresolved ordinary conflicts", context do
      %{plan: plan} =
        build_plan!(context, [
          %{path: "Makefile", content: "test:\n\t@echo proposed\n", executable: false}
        ])

      assert plan.has_ordinary_conflicts == true
      branches_before = git!(context.repository.path, ["branch", "--list"])

      assert {:error, :ordinary_conflicts_present} =
               RepositoryKits.apply_plan(hosted(context), context.project.id, plan.id,
                 repository_path: context.repository.path
               )

      assert git!(context.repository.path, ["branch", "--list"]) == branches_before
    end

    test "refuses a plan with a safety conflict", context do
      %{plan: plan} =
        build_plan!(context, [
          %{path: ".env", content: "SECRET=kit-proposed\n", executable: false}
        ])

      assert plan.safety_blocked == true
      branches_before = git!(context.repository.path, ["branch", "--list"])

      assert {:error, :safety_conflict_present} =
               RepositoryKits.apply_plan(hosted(context), context.project.id, plan.id,
                 repository_path: context.repository.path
               )

      assert git!(context.repository.path, ["branch", "--list"]) == branches_before
    end
  end

  describe "apply_plan/4 successful application" do
    test "applies on a new isolated branch off the exact base commit, leaving the base branch untouched",
         context do
      %{package: package, plan: plan} =
        build_plan!(context, [
          %{path: "NEW_FILE.md", content: "# new\n", executable: false},
          %{path: "nested/dir/FILE.md", content: "nested\n", executable: false}
        ])

      original_branch = git!(context.repository.path, ["symbolic-ref", "--short", "HEAD"])
      original_head = git!(context.repository.path, ["rev-parse", "HEAD"])

      assert {:ok, installation} =
               RepositoryKits.apply_plan(hosted(context), context.project.id, plan.id,
                 repository_path: context.repository.path
               )

      # Provenance fields are copied from the plan.
      assert installation.project_id == context.project.id
      assert installation.package_id == package.id
      assert installation.plan_id == plan.id
      assert installation.package_digest == plan.package_digest
      assert installation.profile_version == plan.profile_version
      assert installation.base_commit == plan.base_commit
      assert installation.root == plan.root
      assert installation.repository_provider == plan.repository_provider
      assert installation.repository_id == plan.repository_id
      assert installation.branch == plan.target_branch
      assert installation.confirmed_by_actor_ref == context.account.id
      assert installation.state == "applied"
      refute installation.result_commit == plan.base_commit

      # The base branch's own ref is exactly unchanged.
      assert git!(context.repository.path, ["rev-parse", original_branch]) == original_head

      # The new branch was created from exactly the base commit, plus one commit.
      merge_base =
        git!(context.repository.path, ["merge-base", original_branch, plan.target_branch])

      assert merge_base == plan.base_commit

      parents = git!(context.repository.path, ["log", "-1", "--format=%P", plan.target_branch])
      assert parents == plan.base_commit

      # The resulting commit contains exactly the intended files: every
      # original fixture file, plus the two newly-created ones.
      files_in_commit =
        context.repository.path
        |> git!(["ls-tree", "-r", "--name-only", plan.target_branch])
        |> String.split("\n", trim: true)
        |> Enum.sort()

      assert files_in_commit ==
               Enum.sort([
                 "AGENTS.md",
                 "README.md",
                 "Makefile",
                 ".env",
                 "NEW_FILE.md",
                 "nested/dir/FILE.md"
               ])

      # The base branch never received these files.
      base_files =
        context.repository.path
        |> git!(["ls-tree", "-r", "--name-only", original_branch])
        |> String.split("\n", trim: true)

      refute "NEW_FILE.md" in base_files
      refute "nested/dir/FILE.md" in base_files
    end

    test "records installed_files with correct paths, digests, sizes, and executable bits",
         context do
      %{plan: plan} =
        build_plan!(context, [
          %{path: "NEW_FILE.md", content: "# new\n", executable: false},
          %{path: "scripts/tool.sh", content: "#!/bin/sh\necho ok\n", executable: true}
        ])

      assert {:ok, installation} =
               RepositoryKits.apply_plan(hosted(context), context.project.id, plan.id,
                 repository_path: context.repository.path
               )

      by_path = Map.new(installation.installed_files, &{&1["path"], &1})

      assert Map.keys(by_path) |> Enum.sort() == ["NEW_FILE.md", "scripts/tool.sh"]

      assert by_path["NEW_FILE.md"]["sha256"] == sha256("# new\n")
      assert by_path["NEW_FILE.md"]["size"] == byte_size("# new\n")
      assert by_path["NEW_FILE.md"]["executable"] == false

      assert by_path["scripts/tool.sh"]["sha256"] == sha256("#!/bin/sh\necho ok\n")
      assert by_path["scripts/tool.sh"]["executable"] == true
    end

    test "the persisted evidence never contains the fixture's absolute repository path or secret-shaped values",
         context do
      %{plan: plan} =
        build_plan!(context, [%{path: "NEW_FILE.md", content: "# new\n", executable: false}])

      assert {:ok, installation} =
               RepositoryKits.apply_plan(hosted(context), context.project.id, plan.id,
                 repository_path: context.repository.path
               )

      evidence_json = Jason.encode!(installation.evidence)
      refute evidence_json =~ context.repository.path
      refute evidence_json =~ "SECRET"

      assert installation.evidence["hooks_disabled"] == true
      assert installation.evidence["committed"] == true
      assert installation.evidence["operations_applied"] == 1
    end
  end

  describe "apply_plan/4 duplicate-apply safety net" do
    test "the unique constraint on plan_id refuses a duplicate installation row for the same plan",
         context do
      %{package: package, plan: plan} = build_plan!(context, default_files())

      attrs = installation_attrs(context, package, plan)

      assert {:ok, _first} =
               attrs |> RepositoryKitInstallation.create_changeset() |> Repo.insert()

      assert {:error, changeset} =
               attrs
               |> Map.put(:id, Ecto.UUID.generate())
               |> RepositoryKitInstallation.create_changeset()
               |> Repo.insert()

      assert %{plan_id: ["has already been taken"]} = errors_on(changeset)
    end

    test "apply_plan/4 is idempotent for a repeat call with the same plan_id, even after its branch is removed out from under it",
         context do
      %{plan: plan} = build_plan!(context, default_files())

      assert {:ok, installation} =
               RepositoryKits.apply_plan(hosted(context), context.project.id, plan.id,
                 repository_path: context.repository.path
               )

      # Superseded by Task 5's idempotent-replay short-circuit (AC-09): this
      # test used to delete the branch out from under the next attempt to
      # defeat WorkerKitApply's own natural `:branch_conflict` refusal, so
      # the flow would reach this schema's unique-constraint safety net and
      # observe the `:already_installed` mapping. `apply_plan/4` now
      # short-circuits on a repeat `plan_id` before ever reaching
      # `WorkerKitApply` or that constraint, so a repeat call succeeds
      # idempotently regardless of what happened to the branch — exactly
      # the behavior this test's own prior comment already anticipated
      # ("idempotent re-apply is explicitly Task 5's job (AC-09)"). The
      # unique-constraint safety net itself is unaffected by this change and
      # remains covered directly by the sibling test above.
      git!(context.repository.path, ["checkout", "--quiet", plan.base_commit])
      git!(context.repository.path, ["branch", "-D", installation.branch])

      assert {:ok, replay} =
               RepositoryKits.apply_plan(hosted(context), context.project.id, plan.id,
                 repository_path: context.repository.path
               )

      assert replay.id == installation.id
      refute branch_exists?(context.repository.path, installation.branch)
    end
  end

  describe "WorkerKitApply.apply/5 default-branch negative" do
    test "refuses every spelling on the default-branch forbidden list before creating a branch",
         context do
      operations = [create_operation("NEW_FILE.md", "# new\n")]

      for forbidden <- ["main", "Main", "MASTER", "refs/heads/main", "HEAD", "head"] do
        assert {:error, :default_branch_forbidden} =
                 WorkerKitApply.apply(
                   context.repository.path,
                   context.repository.commit,
                   ".",
                   forbidden,
                   operations
                 )
      end

      # No sdd-kit branch was ever created for any of these refusals.
      refute branch_exists?(context.repository.path, "sdd-kit/anything")
    end
  end

  describe "WorkerKitApply.apply/5 operation allowlist" do
    test "refuses a disallowed operation kind before creating any branch", context do
      operations = [
        %{
          "path" => "NEW_FILE.md",
          "kind" => "delete",
          "conflict_severity" => nil,
          "proposed_sha256" => sha256("x"),
          "existing_sha256" => nil,
          "proposed_size" => 1,
          "proposed_executable" => false,
          "proposed_content_base64" => Base.encode64("x"),
          "reason" => "hand-built, disallowed kind"
        }
      ]

      assert {:error, :invalid_operation} =
               WorkerKitApply.apply(
                 context.repository.path,
                 context.repository.commit,
                 ".",
                 "sdd-kit/disallowed",
                 operations
               )

      refute branch_exists?(context.repository.path, "sdd-kit/disallowed")
    end

    test "a plan operation kind of conflict is refused, never applied", context do
      operations = [
        create_operation("NEW_FILE.md", "# new\n"),
        %{
          "path" => "Makefile",
          "kind" => "conflict",
          "conflict_severity" => "ordinary",
          "proposed_sha256" => sha256("x"),
          "existing_sha256" => sha256("existing"),
          "proposed_size" => 1,
          "proposed_executable" => false,
          "proposed_content_base64" => Base.encode64("x"),
          "reason" => "existing file content differs"
        }
      ]

      assert {:error, :invalid_operation} =
               WorkerKitApply.apply(
                 context.repository.path,
                 context.repository.commit,
                 ".",
                 "sdd-kit/conflict-op",
                 operations
               )

      refute branch_exists?(context.repository.path, "sdd-kit/conflict-op")
    end
  end

  describe "WorkerKitApply.apply/5 unexpected-file (TOCTOU defense)" do
    test "refuses when a create target already exists and the operation expected nothing there",
         context do
      operations = [create_operation("README.md", "# proposed replacement\n")]

      assert {:error, :unexpected_file} =
               WorkerKitApply.apply(
                 context.repository.path,
                 context.repository.commit,
                 ".",
                 "sdd-kit/unexpected",
                 operations
               )

      refute branch_exists?(context.repository.path, "sdd-kit/unexpected")
    end
  end

  describe "WorkerKitApply.apply/5 partial-failure rollback" do
    test "rolls back safely when a later create operation fails, leaving no half-applied branch",
         context do
      original_branch = git!(context.repository.path, ["symbolic-ref", "--short", "HEAD"])
      original_head = git!(context.repository.path, ["rev-parse", "HEAD"])

      operations = [
        create_operation("OK_FILE.md", "# ok\n"),
        create_operation("Makefile", "unexpected\n")
      ]

      assert {:error, :unexpected_file} =
               WorkerKitApply.apply(
                 context.repository.path,
                 context.repository.commit,
                 ".",
                 "sdd-kit/partial-failure",
                 operations
               )

      refute branch_exists?(context.repository.path, "sdd-kit/partial-failure")
      assert git!(context.repository.path, ["symbolic-ref", "--short", "HEAD"]) == original_branch
      assert git!(context.repository.path, ["rev-parse", "HEAD"]) == original_head
      assert git!(context.repository.path, ["rev-parse", original_branch]) == original_head

      # The working tree, not just the branch and HEAD, is restored to
      # exactly its pre-apply state: the first operation's file, physically
      # written to disk before the second operation failed, is not left
      # behind as untracked debris.
      assert git!(context.repository.path, ["status", "--porcelain"]) == ""
      refute File.exists?(Path.join(context.repository.path, "OK_FILE.md"))
    end
  end

  describe "WorkerKitApply.apply/5 path and symlink containment" do
    test "refuses a create path that escapes root through a pre-existing symlinked directory" do
      repository = symlinked_repository_fixture()
      operations = [create_operation("linked/evil.txt", "evil\n")]

      assert {:error, :symlink_escape} =
               WorkerKitApply.apply(
                 repository.path,
                 repository.commit,
                 ".",
                 "sdd-kit/symlink-escape",
                 operations
               )

      refute branch_exists?(repository.path, "sdd-kit/symlink-escape")
    end

    test "refuses a hand-built create path that escapes root via a .. segment", context do
      # Not reachable through the normal planning pipeline (both
      # `RepositoryKits.publish_package/2` and
      # `WorkerKitComparison.validate_kit_paths/1` already reject a `..`
      # segment upstream); hand-built here, same defense-in-depth pattern as
      # the operation-allowlist tests above.
      operations = [create_operation("../escape.txt", "evil\n")]

      assert {:error, :path_escape} =
               WorkerKitApply.apply(
                 context.repository.path,
                 context.repository.commit,
                 ".",
                 "sdd-kit/path-escape",
                 operations
               )

      refute branch_exists?(context.repository.path, "sdd-kit/path-escape")
    end
  end

  describe "WorkerKitApply.apply/5 hooks-disabled" do
    test "never executes a pre-commit or post-checkout repository hook during apply", context do
      sentinel =
        Path.join(
          System.tmp_dir!(),
          "worker_kit_apply_hooks_#{System.unique_integer([:positive])}"
        )

      on_exit(fn -> File.rm(sentinel) end)

      install_hook!(context.repository.path, "pre-commit", sentinel)
      install_hook!(context.repository.path, "post-checkout", sentinel)

      operations = [create_operation("NEW_FILE.md", "# new\n")]

      assert {:ok, result} =
               WorkerKitApply.apply(
                 context.repository.path,
                 context.repository.commit,
                 ".",
                 "sdd-kit/hooks",
                 operations
               )

      assert result.evidence["hooks_disabled"] == true
      refute File.exists?(sentinel)
    end
  end

  ## Plan-building helper (mirrors RepositoryKitChangePlanTest's fixture chain)

  defp default_files, do: [%{path: "NEW_FILE.md", content: "# new\n", executable: false}]

  defp build_plan!(context, files) do
    profile = approve!(context, context.repository.commit, @instruction_findings)
    {_selection, current} = select_pilot!(context, profile)
    link_feature!(context, current.specification.id, "ready_for_review")

    package = publish_kit_package_fixture(%{}, files)

    assert {:ok, plan} =
             RepositoryKits.plan_change(hosted(context), context.project.id, package.id,
               repository_path: context.repository.path
             )

    %{package: package, plan: plan}
  end

  defp installation_attrs(context, package, plan) do
    %{
      id: Ecto.UUID.generate(),
      project_id: context.project.id,
      package_id: package.id,
      plan_id: plan.id,
      package_digest: plan.package_digest,
      profile_version: plan.profile_version,
      base_commit: plan.base_commit,
      root: plan.root,
      repository_provider: plan.repository_provider,
      repository_id: plan.repository_id,
      branch: plan.target_branch,
      result_commit: plan.base_commit,
      installed_files: [],
      confirmed_by_actor_ref: context.account.id,
      confirmed_at: context.now
    }
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

  defp transition_path("ready_for_review"),
    do: ~w(ready_for_development in_development ready_for_review)

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

  ## Assessment and profile fixtures (adapted from RepositoryKitChangePlanTest)

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

  defp publish_kit_package_fixture(attrs_overrides, files) do
    publish_package_fixture(Map.merge(%{scripts: []}, attrs_overrides), files)
  end

  ## Hand-built operation fixture (WorkerKitApply.apply/5 layer)

  defp create_operation(path, content, opts \\ []) do
    %{
      "path" => path,
      "kind" => "create",
      "conflict_severity" => nil,
      "proposed_sha256" => sha256(content),
      "existing_sha256" => Keyword.get(opts, :existing_sha256, nil),
      "proposed_size" => byte_size(content),
      "proposed_executable" => Keyword.get(opts, :executable, false),
      "proposed_content_base64" => Base.encode64(content),
      "reason" => "test fixture"
    }
  end

  defp sha256(content),
    do: content |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

  defp branch_exists?(repository_path, branch) do
    {_output, status} =
      System.cmd("git", [
        "-C",
        repository_path,
        "show-ref",
        "--verify",
        "--quiet",
        "refs/heads/" <> branch
      ])

    status == 0
  end

  defp install_hook!(repository_path, hook_name, sentinel_path) do
    hook_path = Path.join([repository_path, ".git", "hooks", hook_name])
    File.write!(hook_path, "#!/bin/sh\ntouch #{sentinel_path}\n")
    File.chmod!(hook_path, 0o755)
  end

  ## Throwaway git repository fixtures

  defp git_repository_fixture do
    base =
      Path.join(
        System.tmp_dir!(),
        "repository-kit-apply-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(base)

    git!(base, ["init", "-q"])
    git!(base, ["config", "user.email", "task4@example.invalid"])
    git!(base, ["config", "user.name", "Task 4"])

    write!(base, "AGENTS.md", "# Existing repository instructions\n\nFollow these exactly.\n")
    write!(base, "README.md", "# Example project\n")
    write!(base, "Makefile", "test:\n\t@echo existing\n")
    write!(base, ".env", "SECRET=do-not-overwrite\n")

    git!(base, ["add", "."])
    git!(base, ["commit", "-q", "-m", "fixture"])
    commit = git!(base, ["rev-parse", "HEAD"])

    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(base) end)

    %{path: base, commit: commit}
  end

  defp symlinked_repository_fixture do
    base =
      Path.join(
        System.tmp_dir!(),
        "repository-kit-apply-symlink-#{System.unique_integer([:positive])}"
      )

    outside =
      Path.join(
        System.tmp_dir!(),
        "repository-kit-apply-outside-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(base)
    File.mkdir_p!(outside)

    git!(base, ["init", "-q"])
    git!(base, ["config", "user.email", "task4@example.invalid"])
    git!(base, ["config", "user.name", "Task 4"])

    write!(base, "README.md", "# repo\n")
    File.ln_s!(outside, Path.join(base, "linked"))

    git!(base, ["add", "."])
    git!(base, ["commit", "-q", "-m", "fixture with symlink"])
    commit = git!(base, ["rev-parse", "HEAD"])

    ExUnit.Callbacks.on_exit(fn ->
      File.rm_rf!(base)
      File.rm_rf!(outside)
    end)

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
