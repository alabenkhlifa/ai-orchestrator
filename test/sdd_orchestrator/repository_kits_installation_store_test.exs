defmodule SddOrchestrator.RepositoryKitsInstallationStoreTest do
  @moduledoc """
  Focused proof for Task 8: hosted/device storage parity for the
  repository-kit installation, through `RepositoryKits.InstallationStore`
  and its `Hosted`/`Device` adapters.

  Most coverage here exercises the store layer directly (`ChangePlanStore`,
  `InstallationStore`) with lightweight fixtures — a published package and a
  hand-built change plan — exactly as
  `RepositoryKitsChangePlanStoreTest` (Task 7) does for its own store. The
  "device authority end-to-end" describe blocks are the exception: they
  exercise the real `RepositoryKits.apply_plan/4`, `plan_update/4`, and
  `plan_removal/3` against a real throwaway git repository and a real
  approved profile + selected pilot for a device-authoritative project
  (mirroring `ManagedRuntimeProfileTest`'s own device fixture chain), to
  prove this task's actual device dispatch end-to-end. The one deliberate
  gap: the initial "install" plan is built directly through
  `ChangePlanStore.create/2` rather than `RepositoryKits.plan_change/4` —
  `plan_change/4`'s own `eligible_for_kit_offer?/2` gate requires a linked
  `Delivery.Feature`, and `Features.create/3` authorizes through the
  hosted-only `Participation` boundary a device project has no row in,
  exactly the reason `RepositoryKitsChangePlanStoreTest`'s own moduledoc
  already documents for Task 7. `plan_update/4` and `plan_removal/3` carry
  no such gate, so both run for real once an installation exists.
  """

  use SddOrchestrator.DataCase, async: false

  import SddOrchestrator.AccountsFixtures
  import SddOrchestrator.ProjectsFixtures
  import SddOrchestrator.RepositoryKitFixtures

  alias SddOrchestrator.Accounts.DeviceWorkspace
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.DeviceStore.Local
  alias SddOrchestrator.Repo
  alias SddOrchestrator.RepositoryAssessments
  alias SddOrchestrator.RepositoryKits

  alias SddOrchestrator.RepositoryKits.{
    ChangePlanStore,
    InstallationStore,
    RepositoryKitInstallation
  }

  alias SddOrchestrator.RepositoryPilots
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
    store_path =
      Path.join(
        System.tmp_dir!(),
        "repository-kit-installation-store-#{System.unique_integer([:positive])}/store.dets"
      )

    start_supervised!({Local, path: store_path})
    on_exit(fn -> File.rm_rf!(Path.dirname(store_path)) end)

    {:ok, device_workspace} = Devices.establish_workspace()

    {:ok, device_project} =
      Devices.register_project(%{
        name: "Device installation project",
        repository_fingerprint: "device-installation-repository",
        status: "connected"
      })

    account = account_fixture()
    workspace = workspace_fixture(account)
    hosted_project = registered_project(workspace, name: "Hosted installation project")
    device_repository = git_repository_fixture("device")

    %{
      account: account,
      device_project: device_project,
      device_repository: device_repository,
      device_workspace: device_workspace,
      hosted_project: hosted_project,
      workspace: workspace,
      now: DateTime.utc_now() |> DateTime.truncate(:second),
      store_path: store_path
    }
  end

  describe "device authority end-to-end install" do
    test "a full install succeeds end-to-end and current_installation/3 reads it back", context do
      %{package: package, plan: plan, installation: installation} =
        device_install!(context, default_files())

      assert installation.project_id == context.device_project.id
      assert installation.package_id == package.id
      assert installation.plan_id == plan.id
      assert installation.branch == plan.target_branch
      assert installation.state == "applied"
      assert installation.confirmed_by_actor_ref == context.device_workspace.id
      refute installation.result_commit == plan.base_commit

      by_path = Map.new(installation.installed_files, &{&1["path"], &1})
      assert by_path["NEW_FILE.md"]["sha256"] == sha256("# new\n")

      assert {:ok, current} =
               RepositoryKits.current_installation(
                 device_authority(context),
                 context.device_project.id
               )

      assert current.id == installation.id
      assert current.branch == installation.branch
      assert current.result_commit == installation.result_commit
      assert current.state == "applied"

      # No hosted row was ever written for a device-authoritative installation.
      assert Repo.aggregate(RepositoryKitInstallation, :count) == 0
    end

    test "applying the same plan_id twice returns the same installation without a second mutation",
         context do
      %{plan: plan, installation: first} = device_install!(context, default_files())

      assert {:ok, second} =
               RepositoryKits.apply_plan(
                 device_authority(context),
                 context.device_project.id,
                 plan.id,
                 repository_path: context.device_repository.path
               )

      assert second.id == first.id
      assert second.result_commit == first.result_commit
    end
  end

  describe "device authority end-to-end transition" do
    test "a clean update plan applies end-to-end, updates the installation in place, and records history",
         context do
      merged = device_install_and_merge!(context, default_files())

      approve!(
        %{context | now: DateTime.add(context.now, 60, :second)},
        merged.merged_commit,
        @instruction_findings
      )

      select_pilot!(context)

      package2 =
        publish_kit_package_fixture(%{version: "1.1.0"}, [
          %{path: "UPDATED_FILE.md", content: "# updated\n", executable: false}
        ])

      assert {:ok, update_plan} =
               RepositoryKits.plan_update(
                 device_authority(context),
                 context.device_project.id,
                 package2.id,
                 repository_path: context.device_repository.path
               )

      refute update_plan.safety_blocked
      refute update_plan.has_ordinary_conflicts
      assert update_plan.plan_type == "update"

      assert {:ok, installation2} =
               RepositoryKits.apply_plan(
                 device_authority(context),
                 context.device_project.id,
                 update_plan.id,
                 repository_path: context.device_repository.path
               )

      assert installation2.id == merged.installation1.id
      assert installation2.package_id == package2.id
      refute installation2.package_id == merged.package.id
      assert installation2.state == "updated"

      by_path = Map.new(installation2.installed_files, &{&1["path"], &1})
      assert by_path["UPDATED_FILE.md"]["sha256"] == sha256("# updated\n")

      assert length(installation2.history) == 1
      [entry] = installation2.history
      assert entry["event"] == "updated"
      assert entry["package_id"] == merged.package.id
      assert entry["branch"] == merged.installation1.branch
      assert entry["result_commit"] == merged.installation1.result_commit
      assert entry["state"] == "applied"
    end

    test "a clean removal plan applies end-to-end, empties installed_files, and records history",
         context do
      merged = device_install_and_merge!(context, default_files())

      approve!(
        %{context | now: DateTime.add(context.now, 60, :second)},
        merged.merged_commit,
        @instruction_findings
      )

      select_pilot!(context)

      assert {:ok, removal_plan} =
               RepositoryKits.plan_removal(device_authority(context), context.device_project.id,
                 repository_path: context.device_repository.path
               )

      assert removal_plan.plan_type == "removal"
      refute removal_plan.has_ordinary_conflicts

      assert {:ok, installation2} =
               RepositoryKits.apply_plan(
                 device_authority(context),
                 context.device_project.id,
                 removal_plan.id,
                 repository_path: context.device_repository.path
               )

      assert installation2.id == merged.installation1.id
      assert installation2.state == "removed"
      assert installation2.installed_files == []

      assert length(installation2.history) == 1
      [entry] = installation2.history
      assert entry["event"] == "removed"
      assert entry["package_id"] == merged.package.id
      assert entry["branch"] == merged.installation1.branch
      assert entry["state"] == "applied"

      assert {:ok, current} =
               RepositoryKits.current_installation(
                 device_authority(context),
                 context.device_project.id
               )

      assert current.state == "removed"
    end
  end

  describe "cross-authority isolation" do
    test "a hosted authority cannot reach a device project's stored installation", context do
      _kept = install_fixture!(device_authority(context), context.device_project.id)

      assert {:error, :not_found} =
               RepositoryKits.current_installation(
                 hosted_authority(context),
                 context.device_project.id
               )
    end

    test "a device authority cannot reach a hosted project's stored installation", context do
      _kept = install_fixture!(hosted_authority(context), context.hosted_project.id)

      assert {:error, :not_found} =
               RepositoryKits.current_installation(
                 device_authority(context),
                 context.hosted_project.id
               )
    end

    test "a device authority cannot act on a project it does not own", context do
      other_workspace = %DeviceWorkspace{id: Ecto.UUID.generate()}

      assert {:error, :unauthorized} =
               RepositoryKits.apply_plan(
                 {:device, other_workspace},
                 context.device_project.id,
                 Ecto.UUID.generate(),
                 repository_path: "/nonexistent"
               )
    end

    test "apply_plan/4 still refuses a participant viewer", context do
      assert {:error, :unauthorized} =
               RepositoryKits.apply_plan(
                 {:participant, context.account.id, Ecto.UUID.generate()},
                 context.device_project.id,
                 Ecto.UUID.generate(),
                 repository_path: "/nonexistent"
               )
    end
  end

  describe "RepositoryKitInstallation.to_value/1 and from_value/1" do
    test "round-trips a freshly-created installation unchanged", context do
      attrs = installation_value_attrs(context.device_project.id)
      assert {:ok, installation} = RepositoryKitInstallation.build(attrs)

      value = RepositoryKitInstallation.to_value(installation)
      assert {:ok, restored} = RepositoryKitInstallation.from_value(value)
      assert RepositoryKitInstallation.to_value(restored) == value
    end

    test "round-trips a transitioned installation, preserving history and updated_at", context do
      attrs = installation_value_attrs(context.device_project.id)
      assert {:ok, _installation} = RepositoryKitInstallation.build(attrs)

      transitioned_attrs =
        Map.merge(attrs, %{
          state: "updated",
          installed_files: [],
          history: [%{"event" => "updated", "state" => "applied"}],
          updated_at: DateTime.add(attrs.updated_at, 60, :second)
        })

      assert {:ok, transitioned} = RepositoryKitInstallation.build(transitioned_attrs)

      value = RepositoryKitInstallation.to_value(transitioned)
      assert {:ok, restored} = RepositoryKitInstallation.from_value(value)
      assert RepositoryKitInstallation.to_value(restored) == value
      assert restored.history == transitioned_attrs.history
      assert restored.updated_at == transitioned_attrs.updated_at
      assert restored.inserted_at == attrs.inserted_at
    end

    test "rejects a malformed value" do
      assert {:error, :invalid_installation} =
               RepositoryKitInstallation.from_value(%{"not" => "an installation"})
    end

    test "rejects a tampered value", context do
      attrs = installation_value_attrs(context.device_project.id)
      assert {:ok, installation} = RepositoryKitInstallation.build(attrs)

      tampered =
        installation
        |> RepositoryKitInstallation.to_value()
        |> Map.put("base_commit", "not-a-commit")

      assert {:error, :invalid_installation} = RepositoryKitInstallation.from_value(tampered)
    end
  end

  describe "Devices.DeviceStore.Local delete_project/1" do
    test "reports and removes the repository_kit_installation key for that project, leaving another project's untouched",
         context do
      {:ok, other_device_project} =
        Devices.register_project(%{
          name: "Other device installation project",
          repository_fingerprint: "device-installation-repository-other",
          status: "connected"
        })

      kept = install_fixture!(device_authority(context), other_device_project.id)
      _deleted = install_fixture!(device_authority(context), context.device_project.id)

      assert {:ok, result} = Devices.delete_project(context.device_project.id)
      assert result.deleted_repository_kit_installation == true

      assert {:ok, restored} =
               RepositoryKits.current_installation(
                 device_authority(context),
                 other_device_project.id
               )

      assert restored.id == kept.id

      assert {:error, :not_found} =
               RepositoryKits.current_installation(
                 device_authority(context),
                 context.device_project.id
               )
    end
  end

  describe "ChangePlanStore.get/3" do
    test "fetches an exact plan by id for both authorities", context do
      device_plan = change_plan_fixture(device_authority(context), context.device_project.id)
      hosted_plan = change_plan_fixture(hosted_authority(context), context.hosted_project.id)

      assert {:ok, got} =
               ChangePlanStore.get(
                 device_authority(context),
                 context.device_project.id,
                 device_plan.id
               )

      assert got.id == device_plan.id

      assert {:ok, got} =
               ChangePlanStore.get(
                 hosted_authority(context),
                 context.hosted_project.id,
                 hosted_plan.id
               )

      assert got.id == hosted_plan.id
    end

    test "returns :not_found for a wrong id or a plan belonging to a different project/authority",
         context do
      device_plan = change_plan_fixture(device_authority(context), context.device_project.id)

      assert {:error, :not_found} =
               ChangePlanStore.get(
                 device_authority(context),
                 context.device_project.id,
                 Ecto.UUID.generate()
               )

      assert {:error, :not_found} =
               ChangePlanStore.get(
                 hosted_authority(context),
                 context.hosted_project.id,
                 device_plan.id
               )

      other_workspace = %DeviceWorkspace{id: Ecto.UUID.generate()}

      assert {:error, :not_found} =
               ChangePlanStore.get(
                 {:device, other_workspace},
                 context.device_project.id,
                 device_plan.id
               )
    end
  end

  ## Authorities

  defp device_authority(context), do: {:device, context.device_workspace}
  defp hosted_authority(context), do: {:hosted, context.account.id}

  ## Device end-to-end install/update/removal chain

  defp default_files, do: [%{path: "NEW_FILE.md", content: "# new\n", executable: false}]

  defp device_install!(context, files) do
    profile = approve!(context, context.device_repository.commit, @instruction_findings)
    select_pilot!(context)

    package = publish_kit_package_fixture(%{}, files)

    attrs =
      device_plan_attrs(
        context,
        package,
        profile,
        "install",
        context.device_repository.commit,
        files,
        "sdd-kit/device-install-#{System.unique_integer([:positive])}"
      )

    assert {:ok, plan} = ChangePlanStore.create(device_authority(context), attrs)

    assert {:ok, installation} =
             RepositoryKits.apply_plan(
               device_authority(context),
               context.device_project.id,
               plan.id,
               repository_path: context.device_repository.path
             )

    %{package: package, plan: plan, installation: installation}
  end

  defp device_install_and_merge!(context, files) do
    original_branch = git!(context.device_repository.path, ["symbolic-ref", "--short", "HEAD"])

    %{package: package, plan: install_plan, installation: installation1} =
      device_install!(context, files)

    git!(context.device_repository.path, ["checkout", "--quiet", original_branch])
    git!(context.device_repository.path, ["merge", "--ff-only", "-q", installation1.branch])
    merged_commit = git!(context.device_repository.path, ["rev-parse", "HEAD"])

    %{
      package: package,
      install_plan: install_plan,
      installation1: installation1,
      original_branch: original_branch,
      merged_commit: merged_commit
    }
  end

  defp device_plan_attrs(context, package, profile, plan_type, base_commit, files, target_branch) do
    %{
      id: Ecto.UUID.generate(),
      project_id: context.device_project.id,
      package_id: package.id,
      package_digest: package.digest,
      profile_version: profile.version,
      base_commit: base_commit,
      root: ".",
      repository_provider: context.device_project.repository_provider,
      repository_id: context.device_project.repository_id,
      target_branch: target_branch,
      operations:
        Enum.map(files, &create_operation(&1.path, &1.content, executable: &1.executable)),
      expires_at: DateTime.add(context.now, 900, :second) |> DateTime.truncate(:microsecond),
      plan_type: plan_type
    }
  end

  defp create_operation(path, content, opts) do
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

  ## Device assessment, profile, and pilot fixtures (adapted from
  ## ManagedRuntimeProfileTest's own device fixture chain, using a real
  ## commit from the throwaway git repository instead of a fixed placeholder,
  ## since `WorkerKitComparison`/`WorkerKitUpdateComparison`/
  ## `WorkerKitRemovalComparison` all fail closed against the live repository
  ## at that exact commit)

  defp approve!(context, commit, findings) do
    completed = complete!(context, commit, findings)

    assert {:ok, review} =
             RepositoryAssessments.profile_review(device_authority(context), completed.project_id)

    assert {:ok, profile} =
             RepositoryAssessments.approve_profile(
               device_authority(context),
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
               device_authority(context),
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
               project_id: context.device_project.id,
               repository_provider: context.device_project.repository_provider,
               repository_id: context.device_project.repository_id,
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
    assert {:ok, stored} = AssessmentStore.put(device_authority(context), pending)
    stored
  end

  defp select_pilot!(context) do
    current = device_specification_or_current(context)

    assert {:ok, selection} =
             RepositoryPilots.select(device_authority(context), context.device_project.id, %{
               specification_id: current.specification.id,
               revision_id: current.revision.id
             })

    {selection, current}
  end

  defp device_specification_or_current(context) do
    case Process.get({:device_specification, context.device_project.id}) do
      nil ->
        attrs = SpecificationFixtures.specification_attrs(title: "Pilot specification title")

        assert {:ok, current} =
                 SpecificationStore.create(
                   context.device_workspace,
                   context.device_project.id,
                   attrs
                 )

        Process.put({:device_specification, context.device_project.id}, current)
        current

      current ->
        current
    end
  end

  ## Lightweight store-level fixtures (no assessment/profile/pilot chain
  ## needed — mirrors RepositoryKitsChangePlanStoreTest's own `plan_attrs/3`
  ## convention)

  defp change_plan_fixture(authority, project_id, overrides \\ %{}) do
    unique = System.unique_integer([:positive])

    package =
      publish_package_fixture(%{version: "1.0.#{unique}", scripts: []}, [
        %{path: "SKILL.md", content: "# skill #{unique}\n", executable: false}
      ])

    attrs =
      Map.merge(
        %{
          id: Ecto.UUID.generate(),
          project_id: project_id,
          package_id: package.id,
          package_digest: package.digest,
          profile_version: 1,
          base_commit: String.duplicate("1", 40),
          root: ".",
          repository_provider: "github",
          repository_id: "example/repo",
          target_branch: "sdd-kit/test-#{System.unique_integer([:positive])}",
          operations: [valid_operation()],
          expires_at:
            DateTime.utc_now() |> DateTime.add(900, :second) |> DateTime.truncate(:microsecond),
          plan_type: "install"
        },
        overrides
      )

    assert {:ok, plan} = ChangePlanStore.create(authority, attrs)
    plan
  end

  defp valid_operation do
    %{
      "path" => "NEW_FILE.md",
      "kind" => "create",
      "conflict_severity" => nil,
      "proposed_sha256" => String.duplicate("a", 64),
      "existing_sha256" => nil,
      "proposed_size" => 10,
      "proposed_executable" => false,
      "proposed_content_base64" => "IyBOZXcK",
      "reason" => "not present in the repository at the base commit"
    }
  end

  defp install_fixture!(authority, project_id) do
    plan = change_plan_fixture(authority, project_id)

    attrs =
      installation_value_attrs(project_id, %{
        package_id: plan.package_id,
        plan_id: plan.id,
        package_digest: plan.package_digest
      })

    assert {:ok, installation} = InstallationStore.create(authority, attrs)
    installation
  end

  defp installation_value_attrs(project_id, overrides \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Map.merge(
      %{
        id: Ecto.UUID.generate(),
        project_id: project_id,
        package_id: Ecto.UUID.generate(),
        plan_id: Ecto.UUID.generate(),
        package_digest: String.duplicate("a", 64),
        profile_version: 1,
        base_commit: String.duplicate("1", 40),
        root: ".",
        repository_provider: "github",
        repository_id: "example/repo",
        branch: "sdd-kit/test-#{System.unique_integer([:positive])}",
        result_commit: String.duplicate("2", 40),
        installed_files: [
          %{
            "path" => "NEW_FILE.md",
            "sha256" => String.duplicate("a", 64),
            "size" => 10,
            "executable" => false
          }
        ],
        state: "applied",
        evidence: %{},
        confirmed_by_actor_ref: Ecto.UUID.generate(),
        confirmed_at: now,
        history: [],
        inserted_at: now,
        updated_at: now
      },
      overrides
    )
  end

  ## Kit package fixture

  defp publish_kit_package_fixture(attrs_overrides, files) do
    publish_package_fixture(Map.merge(%{scripts: []}, attrs_overrides), files)
  end

  defp sha256(content),
    do: content |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

  ## Throwaway git repository fixture (adapted from RepositoryKitsApplyTest)

  defp git_repository_fixture(label) do
    base =
      Path.join(
        System.tmp_dir!(),
        "repository-kit-installation-store-#{label}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(base)

    git!(base, ["init", "-q"])
    git!(base, ["config", "user.email", "task8@example.invalid"])
    git!(base, ["config", "user.name", "Task 8"])

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
