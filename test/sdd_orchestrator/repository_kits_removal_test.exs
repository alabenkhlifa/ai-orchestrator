defmodule SddOrchestrator.RepositoryKitsRemovalTest do
  @moduledoc """
  Focused proof for Task 6: kit removal (AC-11).

  Mirrors `RepositoryKitsUpdateTest`'s fixture chain (real approved profile,
  real selected pilot, real linked feature, real throwaway git repository,
  never mocked) and reuses `RepositoryKits.plan_change/4`/`apply_plan/4` for
  the initial install, followed by a simulated normal-review merge of the
  install branch and a fresh assessment approval, before exercising
  `plan_removal/3` and `apply_plan/4` for the removal itself.
  """

  use SddOrchestrator.DataCase, async: true

  import SddOrchestrator.RepositoryKitFixtures

  alias SddOrchestrator.Delivery.Features
  alias SddOrchestrator.RepositoryKits
  alias SddOrchestrator.RepositoryKits.WorkerKitRemovalComparison

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
    project = ProjectsFixtures.registered_project(workspace, name: "Kit removal project")
    repository = git_repository_fixture()

    %{
      account: account,
      workspace: workspace,
      project: project,
      repository: repository,
      now: DateTime.utc_now() |> DateTime.truncate(:second)
    }
  end

  describe "WorkerKitRemovalComparison.compare/5 kit-owned classification (AC-11)" do
    test "classifies every installed file by live presence and content", context do
      write!(context.repository.path, "KIT_UNCHANGED.md", "kit unchanged\n")
      write!(context.repository.path, "KIT_MODIFIED.md", "kit modified by user\n")
      git!(context.repository.path, ["add", "."])
      git!(context.repository.path, ["commit", "-q", "-m", "kit-owned fixture files"])
      commit = git!(context.repository.path, ["rev-parse", "HEAD"])

      installed_files = [
        installed_entry("KIT_UNCHANGED.md", "kit unchanged\n"),
        installed_entry("KIT_DELETED.md", "kit deleted\n"),
        installed_entry("KIT_MODIFIED.md", "kit original\n")
      ]

      package_files = [
        proposed_file("KIT_UNCHANGED.md", "kit unchanged\n"),
        proposed_file("KIT_DELETED.md", "kit deleted\n"),
        proposed_file("KIT_MODIFIED.md", "kit original\n")
      ]

      assert {:ok, operations} =
               WorkerKitRemovalComparison.compare(
                 context.repository.path,
                 commit,
                 ".",
                 package_files,
                 installed_files
               )

      by_path = Map.new(operations, &{&1["path"], &1})

      # Kit-owned, unchanged since install -> safe to delete.
      assert by_path["KIT_UNCHANGED.md"]["kind"] == "delete"
      assert by_path["KIT_UNCHANGED.md"]["conflict_severity"] == nil
      assert by_path["KIT_UNCHANGED.md"]["existing_sha256"] == sha256("kit unchanged\n")
      assert by_path["KIT_UNCHANGED.md"]["proposed_sha256"] == sha256("kit unchanged\n")
      assert by_path["KIT_UNCHANGED.md"]["reason"] =~ "safe to remove"

      # Kit-owned, already missing live -> nothing to remove.
      assert by_path["KIT_DELETED.md"]["kind"] == "omit"
      assert by_path["KIT_DELETED.md"]["conflict_severity"] == nil
      assert by_path["KIT_DELETED.md"]["existing_sha256"] == nil
      assert by_path["KIT_DELETED.md"]["reason"] =~ "already absent"

      # Kit-owned, live content changed since it was recorded -> drifted conflict.
      assert by_path["KIT_MODIFIED.md"]["kind"] == "conflict"
      assert by_path["KIT_MODIFIED.md"]["conflict_severity"] == "drifted"
      assert by_path["KIT_MODIFIED.md"]["existing_sha256"] == sha256("kit modified by user\n")
      assert by_path["KIT_MODIFIED.md"]["reason"] =~ "modified since installation"
    end

    test "fails closed when the live repository is no longer at the expected commit", context do
      installed_files = [installed_entry("KIT_UNCHANGED.md", "kit unchanged\n")]
      package_files = [proposed_file("KIT_UNCHANGED.md", "kit unchanged\n")]

      assert {:error, :stale_commit} =
               WorkerKitRemovalComparison.compare(
                 context.repository.path,
                 String.duplicate("0", 40),
                 ".",
                 package_files,
                 installed_files
               )
    end
  end

  describe "plan_removal/3 requires an active installation (AC-11)" do
    test "refuses :not_installed with nothing installed yet", context do
      assert {:error, :not_installed} =
               RepositoryKits.plan_removal(hosted(context), context.project.id,
                 repository_path: context.repository.path
               )
    end

    test "refuses :not_installed again after a kit has already been removed once", context do
      result = install_and_remove!(context, default_files())

      assert result.installation2.state == "removed"

      assert {:error, :not_installed} =
               RepositoryKits.plan_removal(hosted(context), context.project.id,
                 repository_path: context.repository.path
               )

      # The same `fetch_current_installation/1` fix benefits `plan_update/4`
      # too: an already-removed installation is not something a further
      # update can target either.
      assert {:error, :not_installed} =
               RepositoryKits.plan_update(
                 hosted(context),
                 context.project.id,
                 Ecto.UUID.generate(),
                 repository_path: context.repository.path
               )
    end

    test "builds a real removal plan against a real installed kit", context do
      files = [%{path: "NEW_FILE.md", content: "# new\n", executable: false}]
      merged = install_and_merge!(context, files)

      :ok =
        approve_and_reselect!(
          %{context | now: DateTime.add(context.now, 60, :second)},
          merged.merged_commit,
          merged.current
        )

      assert {:ok, plan} =
               RepositoryKits.plan_removal(hosted(context), context.project.id,
                 repository_path: context.repository.path
               )

      assert plan.plan_type == "removal"
      refute plan.safety_blocked
      refute plan.has_ordinary_conflicts
      refute plan.target_branch == merged.install_plan.target_branch

      by_path = Map.new(plan.operations, &{&1["path"], &1})
      assert by_path["NEW_FILE.md"]["kind"] == "delete"
      assert length(plan.operations) == length(merged.installation1.installed_files)
    end
  end

  describe "apply_plan/4 blocks the entire removal plan on drift (AC-11)" do
    test "a hand-edited kit-owned file blocks the whole plan and apply_plan/4 refuses it, deleting nothing",
         context do
      files = [
        %{path: "KEEP_FILE.md", content: "keep me\n", executable: false},
        %{path: "DRIFT_FILE.md", content: "kit original\n", executable: false}
      ]

      merged = install_and_merge!(context, files)

      write!(context.repository.path, "DRIFT_FILE.md", "hand-edited by someone\n")
      git!(context.repository.path, ["add", "DRIFT_FILE.md"])
      git!(context.repository.path, ["commit", "-q", "-m", "user edit"])
      edited_commit = git!(context.repository.path, ["rev-parse", "HEAD"])

      :ok =
        approve_and_reselect!(
          %{context | now: DateTime.add(context.now, 60, :second)},
          edited_commit,
          merged.current
        )

      assert {:ok, removal_plan} =
               RepositoryKits.plan_removal(hosted(context), context.project.id,
                 repository_path: context.repository.path
               )

      assert removal_plan.has_ordinary_conflicts == true
      operation = Enum.find(removal_plan.operations, &(&1["path"] == "DRIFT_FILE.md"))
      assert operation["conflict_severity"] == "drifted"

      keep_before = File.read!(Path.join(context.repository.path, "KEEP_FILE.md"))
      drift_before = File.read!(Path.join(context.repository.path, "DRIFT_FILE.md"))

      assert {:error, :ordinary_conflicts_present} =
               RepositoryKits.apply_plan(
                 hosted(context),
                 context.project.id,
                 removal_plan.id,
                 repository_path: context.repository.path
               )

      assert File.exists?(Path.join(context.repository.path, "KEEP_FILE.md"))
      assert File.read!(Path.join(context.repository.path, "KEEP_FILE.md")) == keep_before
      assert File.read!(Path.join(context.repository.path, "DRIFT_FILE.md")) == drift_before
    end
  end

  describe "apply_plan/4 applies a clean removal plan (AC-11)" do
    test "deletes only kit-owned unchanged files, empties installed_files, and records history",
         context do
      files = [
        %{path: "REMOVE_ME.md", content: "remove me\n", executable: false},
        %{path: "scripts/tool.sh", content: "#!/bin/sh\necho ok\n", executable: true}
      ]

      result = install_and_remove!(context, files)

      refute File.exists?(Path.join(context.repository.path, "REMOVE_ME.md"))
      refute File.exists?(Path.join(context.repository.path, "scripts/tool.sh"))

      diff_lines =
        git!(context.repository.path, [
          "diff",
          "--name-status",
          result.merged_commit,
          result.installation2.result_commit
        ])
        |> String.split("\n", trim: true)

      assert "D\tREMOVE_ME.md" in diff_lines
      assert "D\tscripts/tool.sh" in diff_lines

      assert result.installation2.installed_files == []
      assert result.installation2.state == "removed"

      assert length(result.installation2.history) == 1
      [entry] = result.installation2.history
      assert entry["package_id"] == result.package.id
      assert entry["branch"] == result.installation1.branch
      assert entry["result_commit"] == result.installation1.result_commit
      assert entry["state"] == "applied"
    end

    test "the persisted evidence never contains the fixture's absolute repository path or secret-shaped values",
         context do
      result = install_and_remove!(context, default_files())

      evidence_json = Jason.encode!(result.installation2.evidence)
      refute evidence_json =~ context.repository.path
      refute evidence_json =~ "SECRET"

      assert result.installation2.evidence["hooks_disabled"] == true
      assert result.installation2.evidence["committed"] == true
      assert result.installation2.evidence["operations_applied"] == 0
      assert result.installation2.evidence["operations_deleted"] == 1
    end
  end

  describe "apply_plan/4 idempotent replay of a removal plan (AC-09 continued)" do
    test "replaying the same removal plan_id returns the same installation without touching the repository again",
         context do
      result = install_and_remove!(context, default_files())

      branches_before = git!(context.repository.path, ["branch", "--list"])
      head_before = git!(context.repository.path, ["rev-parse", "HEAD"])

      assert {:ok, second} =
               RepositoryKits.apply_plan(
                 hosted(context),
                 context.project.id,
                 result.removal_plan.id,
                 repository_path: context.repository.path
               )

      assert second.id == result.installation2.id
      assert second.result_commit == result.installation2.result_commit
      assert git!(context.repository.path, ["branch", "--list"]) == branches_before
      assert git!(context.repository.path, ["rev-parse", "HEAD"]) == head_before
    end
  end

  describe "removal branch naming never collides with the install branch (AC-11)" do
    test "removal applies successfully against the same repository the install used, on a distinct branch",
         context do
      result = install_and_remove!(context, default_files())

      refute result.removal_plan.target_branch == result.install_plan.target_branch
      refute result.installation2.branch == result.installation1.branch
      assert branch_exists?(context.repository.path, result.installation1.branch)
      assert branch_exists?(context.repository.path, result.installation2.branch)
    end
  end

  ## Install + merge + removal helpers

  defp default_files, do: [%{path: "NEW_FILE.md", content: "# new\n", executable: false}]

  # Installs a package on its own isolated branch, then simulates the owner
  # merging that branch into the repository's own default branch through its
  # normal review process (installation itself never merges) — required
  # before any later removal plan's live comparison can see a kit-owned file
  # as present, exactly as `RepositoryKitsUpdateTest`'s own end-to-end update
  # tests require for the same reason.
  defp install_and_merge!(context, files) do
    original_branch = git!(context.repository.path, ["symbolic-ref", "--short", "HEAD"])

    profile1 = approve!(context, context.repository.commit, @instruction_findings)
    {_selection, current} = select_pilot!(context, profile1)
    link_feature!(context, current.specification.id, "ready_for_review")

    package = publish_kit_package_fixture(%{}, files)

    assert {:ok, install_plan} =
             RepositoryKits.plan_change(hosted(context), context.project.id, package.id,
               repository_path: context.repository.path
             )

    assert {:ok, installation1} =
             RepositoryKits.apply_plan(hosted(context), context.project.id, install_plan.id,
               repository_path: context.repository.path
             )

    git!(context.repository.path, ["checkout", "--quiet", original_branch])
    git!(context.repository.path, ["merge", "--ff-only", "-q", installation1.branch])
    merged_commit = git!(context.repository.path, ["rev-parse", "HEAD"])

    %{
      package: package,
      current: current,
      install_plan: install_plan,
      installation1: installation1,
      original_branch: original_branch,
      merged_commit: merged_commit
    }
  end

  # A fresh assessment approval bound to `commit`, and the pilot re-pinned to
  # it. `RepositoryAssessment.pending/2` stamps `inserted_at` from the
  # caller-supplied `now` verbatim (not from real insert-time), and
  # `AssessmentStore.latest/2` breaks an `inserted_at` tie on `id desc` — a
  # random UUID comparison — so `context.now` here must strictly advance past
  # whatever `now` the first `approve!/3` used, exactly as
  # `RepositoryKitsUpdateTest` documents for the same reason.
  defp approve_and_reselect!(context, commit, current) do
    approve!(context, commit, @instruction_findings)

    assert {:ok, _reselection} =
             RepositoryPilots.select(hosted(context), context.project.id, %{
               specification_id: current.specification.id,
               revision_id: current.revision.id
             })

    :ok
  end

  defp install_and_remove!(context, files) do
    merged = install_and_merge!(context, files)

    :ok =
      approve_and_reselect!(
        %{context | now: DateTime.add(context.now, 60, :second)},
        merged.merged_commit,
        merged.current
      )

    assert {:ok, removal_plan} =
             RepositoryKits.plan_removal(hosted(context), context.project.id,
               repository_path: context.repository.path
             )

    assert {:ok, installation2} =
             RepositoryKits.apply_plan(
               hosted(context),
               context.project.id,
               removal_plan.id,
               repository_path: context.repository.path
             )

    Map.merge(merged, %{removal_plan: removal_plan, installation2: installation2})
  end

  ## WorkerKitRemovalComparison fixtures

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

  ## Feature and eligibility fixtures (adapted from RepositoryKitsUpdateTest)

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

  ## Assessment and profile fixtures (adapted from RepositoryKitsUpdateTest)

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

  ## Throwaway git repository fixture (adapted from RepositoryKitsUpdateTest)

  defp git_repository_fixture do
    base =
      Path.join(
        System.tmp_dir!(),
        "repository-kit-removal-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(base)

    git!(base, ["init", "-q"])
    git!(base, ["config", "user.email", "task6@example.invalid"])
    git!(base, ["config", "user.name", "Task 6"])

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
