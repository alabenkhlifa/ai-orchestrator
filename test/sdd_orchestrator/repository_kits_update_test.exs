defmodule SddOrchestrator.RepositoryKitsUpdateTest do
  @moduledoc """
  Focused proof for Task 5: idempotent apply (AC-09) and kit update (AC-10).

  Mirrors `RepositoryKitsApplyTest`'s and `RepositoryKitChangePlanTest`'s
  fixture chain (real approved profile, real selected pilot, real linked
  feature, real throwaway git repository, never mocked) and reuses
  `RepositoryKits.plan_change/4`/`apply_plan/4` for the initial install
  before exercising `plan_update/4` and idempotent replay against it.
  """

  use SddOrchestrator.DataCase, async: true

  import SddOrchestrator.RepositoryKitFixtures

  alias SddOrchestrator.Delivery.Features
  alias SddOrchestrator.RepositoryKits
  alias SddOrchestrator.RepositoryKits.WorkerKitUpdateComparison

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
    project = ProjectsFixtures.registered_project(workspace, name: "Kit update project")
    repository = git_repository_fixture()

    %{
      account: account,
      workspace: workspace,
      project: project,
      repository: repository,
      now: DateTime.utc_now() |> DateTime.truncate(:second)
    }
  end

  describe "apply_plan/4 idempotent replay (AC-09)" do
    test "replaying the same plan_id returns the same installation without touching the repository again",
         context do
      %{plan: plan, installation: first} = install!(context, default_files())

      branches_before = git!(context.repository.path, ["branch", "--list"])
      head_before = git!(context.repository.path, ["rev-parse", "HEAD"])

      assert {:ok, second} =
               RepositoryKits.apply_plan(hosted(context), context.project.id, plan.id,
                 repository_path: context.repository.path
               )

      assert second.id == first.id
      assert second.result_commit == first.result_commit
      assert git!(context.repository.path, ["branch", "--list"]) == branches_before
      assert git!(context.repository.path, ["rev-parse", "HEAD"]) == head_before
    end

    test "applying a second, different plan is never treated as a replay of the first (changed input)",
         context do
      %{package: package1, plan: plan1, installation: first} = install!(context, default_files())

      # Return the live repository to the exact original base commit — the
      # install's own isolated branch and commit never moved the base
      # branch, so `ManagedRuntimeProfile.build/3` still resolves the same
      # approved profile and base commit for a second, independent plan.
      git!(context.repository.path, ["checkout", "--quiet", context.repository.commit])

      package2 =
        publish_kit_package_fixture(%{version: "1.1.0"}, [
          %{path: "SECOND_FILE.md", content: "# second\n", executable: false}
        ])

      assert {:ok, plan2} =
               RepositoryKits.plan_update(hosted(context), context.project.id, package2.id,
                 repository_path: context.repository.path
               )

      refute plan2.id == plan1.id

      assert {:ok, second} =
               RepositoryKits.apply_plan(hosted(context), context.project.id, plan2.id,
                 repository_path: context.repository.path
               )

      # Same installation row (Task 5's design: one current row per project,
      # updated in place across an update), but a genuinely new result —
      # never a silent replay of the first apply's outcome.
      assert second.id == first.id
      assert second.plan_id == plan2.id
      refute second.plan_id == plan1.id
      refute second.branch == first.branch
      refute second.result_commit == first.result_commit
      assert second.package_id == package2.id
      refute second.package_id == package1.id
    end
  end

  describe "a newer catalog package is information only (AC-10)" do
    test "a newer package existing alone never changes the installed files, branch, or state",
         context do
      %{package: package1, installation: installation} = install!(context, default_files())

      _package2 =
        publish_kit_package_fixture(%{version: "9.9.9"}, [
          %{path: "SECOND_FILE.md", content: "x", executable: false}
        ])

      assert {:ok, current} =
               RepositoryKits.current_installation(hosted(context), context.project.id)

      assert current.id == installation.id
      assert current.package_id == package1.id
      assert current.branch == installation.branch
      assert current.result_commit == installation.result_commit
      assert current.installed_files == installation.installed_files
      assert current.state == "applied"
      assert current.history == []
    end
  end

  describe "WorkerKitUpdateComparison.compare/6 kit-owned classification (AC-10)" do
    test "classifies every not-owned and owned-since-install branch", context do
      write!(context.repository.path, "KIT_UNCHANGED.md", "kit unchanged\n")
      write!(context.repository.path, "KIT_TO_UPDATE.md", "kit v1\n")
      write!(context.repository.path, "KIT_MODIFIED.md", "kit modified by user\n")
      git!(context.repository.path, ["add", "."])
      git!(context.repository.path, ["commit", "-q", "-m", "kit-owned fixture files"])
      commit = git!(context.repository.path, ["rev-parse", "HEAD"])

      installed_files = [
        installed_entry("KIT_UNCHANGED.md", "kit unchanged\n"),
        installed_entry("KIT_TO_UPDATE.md", "kit v1\n"),
        installed_entry("KIT_DELETED.md", "kit deleted\n"),
        installed_entry("KIT_MODIFIED.md", "kit original\n")
      ]

      proposed_files = [
        proposed_file("NEW_FILE.md", "new\n"),
        proposed_file("README.md", readme_content()),
        proposed_file("Makefile", "test:\n\t@echo proposed\n"),
        proposed_file("KIT_UNCHANGED.md", "kit unchanged\n"),
        proposed_file("KIT_TO_UPDATE.md", "kit v2\n"),
        proposed_file("KIT_DELETED.md", "kit deleted replacement\n"),
        proposed_file("KIT_MODIFIED.md", "kit new proposal\n")
      ]

      assert {:ok, operations} =
               WorkerKitUpdateComparison.compare(
                 context.repository.path,
                 commit,
                 ".",
                 proposed_files,
                 MapSet.new(),
                 installed_files
               )

      by_path = Map.new(operations, &{&1["path"], &1})

      # Not currently kit-owned, absent live -> create.
      assert by_path["NEW_FILE.md"]["kind"] == "create"
      assert by_path["NEW_FILE.md"]["conflict_severity"] == nil
      assert by_path["NEW_FILE.md"]["existing_sha256"] == nil

      # Not currently kit-owned, identical live content -> create (no-op).
      assert by_path["README.md"]["kind"] == "create"
      assert by_path["README.md"]["conflict_severity"] == nil
      assert by_path["README.md"]["existing_sha256"] == sha256(readme_content())

      # Not currently kit-owned, different live content -> ordinary conflict.
      assert by_path["Makefile"]["kind"] == "conflict"
      assert by_path["Makefile"]["conflict_severity"] == "ordinary"
      assert by_path["Makefile"]["existing_sha256"] == sha256("test:\n\t@echo existing\n")

      # Kit-owned, unchanged since install, proposed content identical.
      assert by_path["KIT_UNCHANGED.md"]["kind"] == "create"
      assert by_path["KIT_UNCHANGED.md"]["conflict_severity"] == nil
      assert by_path["KIT_UNCHANGED.md"]["reason"] =~ "already matches"
      assert by_path["KIT_UNCHANGED.md"]["existing_sha256"] == sha256("kit unchanged\n")

      # Kit-owned, unchanged since install, proposed content differs -> safe update.
      assert by_path["KIT_TO_UPDATE.md"]["kind"] == "create"
      assert by_path["KIT_TO_UPDATE.md"]["conflict_severity"] == nil
      assert by_path["KIT_TO_UPDATE.md"]["reason"] =~ "will be updated"
      assert by_path["KIT_TO_UPDATE.md"]["existing_sha256"] == sha256("kit v1\n")

      # Kit-owned, missing live (deleted since install) -> drifted conflict.
      assert by_path["KIT_DELETED.md"]["kind"] == "conflict"
      assert by_path["KIT_DELETED.md"]["conflict_severity"] == "drifted"
      assert by_path["KIT_DELETED.md"]["existing_sha256"] == nil
      assert by_path["KIT_DELETED.md"]["reason"] =~ "removed since installation"

      # Kit-owned, live content changed since install -> drifted conflict.
      assert by_path["KIT_MODIFIED.md"]["kind"] == "conflict"
      assert by_path["KIT_MODIFIED.md"]["conflict_severity"] == "drifted"
      assert by_path["KIT_MODIFIED.md"]["existing_sha256"] == sha256("kit modified by user\n")
      assert by_path["KIT_MODIFIED.md"]["reason"] =~ "modified since installation"
    end
  end

  describe "end-to-end update plan and apply (AC-10)" do
    test "a hand-edited kit-owned file blocks the update plan and apply_plan/4 refuses it, leaving the file untouched",
         context do
      original_branch = git!(context.repository.path, ["symbolic-ref", "--short", "HEAD"])

      profile1 = approve!(context, context.repository.commit, @instruction_findings)
      {_selection, current} = select_pilot!(context, profile1)
      link_feature!(context, current.specification.id, "ready_for_review")

      package1 =
        publish_kit_package_fixture(%{}, [
          %{path: "KIT_FILE.md", content: "kit v1\n", executable: false}
        ])

      assert {:ok, plan1} =
               RepositoryKits.plan_change(hosted(context), context.project.id, package1.id,
                 repository_path: context.repository.path
               )

      assert {:ok, installation1} =
               RepositoryKits.apply_plan(hosted(context), context.project.id, plan1.id,
                 repository_path: context.repository.path
               )

      # Simulate the owner merging the reviewed install branch into the
      # default branch through the repository's own normal review process —
      # installation itself never merges, so this step is required before
      # any later update plan's live comparison can see a kit-owned file.
      git!(context.repository.path, ["checkout", "--quiet", original_branch])
      git!(context.repository.path, ["merge", "--ff-only", "-q", installation1.branch])
      merged_commit = git!(context.repository.path, ["rev-parse", "HEAD"])
      assert merged_commit == installation1.result_commit

      # Someone hand-edits the kit-owned file after the merge.
      write!(context.repository.path, "KIT_FILE.md", "hand-edited by someone\n")
      git!(context.repository.path, ["add", "KIT_FILE.md"])
      git!(context.repository.path, ["commit", "-q", "-m", "user edit"])
      edited_commit = git!(context.repository.path, ["rev-parse", "HEAD"])

      # A fresh assessment approval binds a new execution-profile version at
      # this new (post-hand-edit) live commit, exactly as a real re-scan
      # would report, and the pilot is re-pinned to it. The live repository
      # must sit at the exact commit a plan compares against, so the
      # approval happens after the hand edit, not before it.
      #
      # `RepositoryAssessment.pending/2` stamps `inserted_at` from the
      # caller-supplied `now` verbatim (not from real insert-time), and
      # `AssessmentStore.latest/2` breaks an `inserted_at` tie on `id desc`
      # — a random UUID comparison. Reusing the frozen `context.now` for
      # both approvals would tie their `inserted_at` and make "latest
      # assessment" non-deterministic; a strictly later `now` for the
      # second approval avoids that tie (same pattern
      # `managed_runtime_profile_test.exs` already uses for the same
      # reason).
      approve!(
        %{context | now: DateTime.add(context.now, 60, :second)},
        edited_commit,
        @instruction_findings
      )

      assert {:ok, _reselection} =
               RepositoryPilots.select(hosted(context), context.project.id, %{
                 specification_id: current.specification.id,
                 revision_id: current.revision.id
               })

      package2 =
        publish_kit_package_fixture(%{version: "1.1.0"}, [
          %{path: "KIT_FILE.md", content: "kit v2\n", executable: false}
        ])

      assert {:ok, update_plan} =
               RepositoryKits.plan_update(hosted(context), context.project.id, package2.id,
                 repository_path: context.repository.path
               )

      assert update_plan.has_ordinary_conflicts == true
      operation = Enum.find(update_plan.operations, &(&1["path"] == "KIT_FILE.md"))
      assert operation["conflict_severity"] == "drifted"

      content_before = File.read!(Path.join(context.repository.path, "KIT_FILE.md"))

      assert {:error, :ordinary_conflicts_present} =
               RepositoryKits.apply_plan(hosted(context), context.project.id, update_plan.id,
                 repository_path: context.repository.path
               )

      assert File.read!(Path.join(context.repository.path, "KIT_FILE.md")) == content_before
    end

    test "a clean update plan applies on a fresh isolated branch, updates the installation row in place, and records history",
         context do
      original_branch = git!(context.repository.path, ["symbolic-ref", "--short", "HEAD"])

      profile1 = approve!(context, context.repository.commit, @instruction_findings)
      {_selection, current} = select_pilot!(context, profile1)
      link_feature!(context, current.specification.id, "ready_for_review")

      package1 =
        publish_kit_package_fixture(%{}, [
          %{path: "KIT_FILE.md", content: "kit v1\n", executable: false}
        ])

      assert {:ok, plan1} =
               RepositoryKits.plan_change(hosted(context), context.project.id, package1.id,
                 repository_path: context.repository.path
               )

      assert {:ok, installation1} =
               RepositoryKits.apply_plan(hosted(context), context.project.id, plan1.id,
                 repository_path: context.repository.path
               )

      install_branch_commit = git!(context.repository.path, ["rev-parse", installation1.branch])

      git!(context.repository.path, ["checkout", "--quiet", original_branch])
      git!(context.repository.path, ["merge", "--ff-only", "-q", installation1.branch])
      merged_commit = git!(context.repository.path, ["rev-parse", "HEAD"])

      # See the sibling "hand-edited" test above for why `now` must strictly
      # advance between two approvals in the same test:
      # `RepositoryAssessment.pending/2` stamps `inserted_at` from `now`
      # verbatim, and `AssessmentStore.latest/2` breaks an `inserted_at` tie
      # on a random UUID.
      approve!(
        %{context | now: DateTime.add(context.now, 60, :second)},
        merged_commit,
        @instruction_findings
      )

      assert {:ok, _reselection} =
               RepositoryPilots.select(hosted(context), context.project.id, %{
                 specification_id: current.specification.id,
                 revision_id: current.revision.id
               })

      package2 =
        publish_kit_package_fixture(%{version: "1.1.0"}, [
          %{path: "KIT_FILE.md", content: "kit v2\n", executable: false}
        ])

      assert {:ok, update_plan} =
               RepositoryKits.plan_update(hosted(context), context.project.id, package2.id,
                 repository_path: context.repository.path
               )

      refute update_plan.safety_blocked
      refute update_plan.has_ordinary_conflicts
      assert update_plan.plan_type == "update"
      refute update_plan.target_branch == installation1.branch

      assert {:ok, installation2} =
               RepositoryKits.apply_plan(hosted(context), context.project.id, update_plan.id,
                 repository_path: context.repository.path
               )

      # Same row, updated in place.
      assert installation2.id == installation1.id
      assert installation2.package_id == package2.id
      refute installation2.package_id == installation1.package_id
      assert installation2.branch == update_plan.target_branch
      refute installation2.branch == installation1.branch
      refute installation2.result_commit == installation1.result_commit
      assert installation2.state == "updated"

      by_path = Map.new(installation2.installed_files, &{&1["path"], &1})
      assert by_path["KIT_FILE.md"]["sha256"] == sha256("kit v2\n")

      assert length(installation2.history) == 1
      [entry] = installation2.history
      assert entry["event"] == "updated"
      assert entry["package_id"] == package1.id
      assert entry["branch"] == installation1.branch
      assert entry["result_commit"] == installation1.result_commit
      assert entry["state"] == "applied"

      # The original install branch is completely untouched: still exactly
      # the one commit from the first apply.
      assert git!(context.repository.path, ["rev-parse", installation1.branch]) ==
               install_branch_commit
    end
  end

  ## Install helper (mirrors RepositoryKitsApplyTest's own build+apply chain)

  defp default_files, do: [%{path: "NEW_FILE.md", content: "# new\n", executable: false}]

  defp install!(context, files) do
    profile = approve!(context, context.repository.commit, @instruction_findings)
    {_selection, current} = select_pilot!(context, profile)
    link_feature!(context, current.specification.id, "ready_for_review")

    package = publish_kit_package_fixture(%{}, files)

    assert {:ok, plan} =
             RepositoryKits.plan_change(hosted(context), context.project.id, package.id,
               repository_path: context.repository.path
             )

    assert {:ok, installation} =
             RepositoryKits.apply_plan(hosted(context), context.project.id, plan.id,
               repository_path: context.repository.path
             )

    %{package: package, plan: plan, installation: installation, current: current}
  end

  ## WorkerKitUpdateComparison fixtures

  defp installed_entry(path, content) do
    %{
      "path" => path,
      "sha256" => sha256(content),
      "size" => byte_size(content),
      "executable" => false
    }
  end

  defp proposed_file(path, content) do
    %{
      "path" => path,
      "content" => Base.encode64(content),
      "sha256" => sha256(content),
      "size" => byte_size(content),
      "executable" => false
    }
  end

  ## Feature and eligibility fixtures (adapted from RepositoryKitsApplyTest)

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

  ## Assessment and profile fixtures (adapted from RepositoryKitsApplyTest)

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

  defp publish_kit_package_fixture(attrs_overrides, files) do
    publish_package_fixture(Map.merge(%{scripts: []}, attrs_overrides), files)
  end

  defp sha256(content),
    do: content |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

  ## Throwaway git repository fixture (adapted from RepositoryKitsApplyTest)

  defp git_repository_fixture do
    base =
      Path.join(
        System.tmp_dir!(),
        "repository-kit-update-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(base)

    git!(base, ["init", "-q"])
    git!(base, ["config", "user.email", "task5@example.invalid"])
    git!(base, ["config", "user.name", "Task 5"])

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
