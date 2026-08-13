defmodule SddOrchestrator.Privacy.RepositoryKitPrivacyTest do
  @moduledoc """
  Task 9 governance-proof for the repository-sdd-kit domain (AC-12, AC-13).

  Tasks 1 through 8 already extensively cover this domain's own business
  rules and authorization boundaries per function: owner-vs-participant and
  hosted-vs-device authorization for every `RepositoryKits` entry point
  (`repository_kits_apply_test.exs`, `repository_kits_update_test.exs`,
  `repository_kits_removal_test.exs`), per-task evidence hygiene proving the
  persisted `evidence`/`installed_files` never carry an absolute fixture
  repository path or a secret-shaped value (those same three files' own "the
  persisted evidence never contains..." tests), and hosted/device
  cross-authority isolation for both new entities
  (`repository_kits_change_plan_store_test.exs`'s and
  `repository_kits_installation_store_test.exs`'s own "cross-authority
  isolation" describe blocks). This file does not repeat any of that
  coverage.

  What nothing else in this slice proves, with real deletes and real
  `Retention`/`Rights` calls rather than mocks:

    * real end-to-end deletion of `RepositoryKitChangePlan` and
      `RepositoryKitInstallation` through the hosted project cascade, the
      GDPR account-erasure path, and the device project cascade — and that
      the global `RepositoryKitPackage` catalog is untouched by any of the
      three, since it carries no `project_id` and is never project-scoped;
    * `Retention.prune_all/1` correctly does not need to reach any of these
      three tables, because they are bounded by project lifecycle rather
      than a retention timer;
    * neither the domain module nor its store adapters log or inspect their
      own data, and none of the three tables is analytics-shaped;
    * no new processor or cross-border transfer relationship (repository-kit
      planning and apply only ever shell out to `git`, never make an HTTP
      call, and introduce no new third-party dependency);
    * the AC-13 specification-authority invariant: nothing in the
      plan/apply/update/removal machinery reads or writes actual
      specification/revision content, vendors it into a package, or exports
      it into the repository — the only touchpoint into the specification
      domain is the one already-approved, already-tested read
      `eligible_for_kit_offer?/2` makes through
      `Delivery.Features.fetch_by_specification/2` (a read of
      `lifecycle_column` only).
  """

  use SddOrchestrator.DataCase, async: false

  import SddOrchestrator.RepositoryKitFixtures

  alias SddOrchestrator.Delivery.Features
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.DeviceStore.Local
  alias SddOrchestrator.Privacy.{Retention, Rights}
  alias SddOrchestrator.Repo
  alias SddOrchestrator.RepositoryKits

  alias SddOrchestrator.RepositoryKits.{
    ChangePlanStore,
    InstallationStore,
    RepositoryKitChangePlan,
    RepositoryKitInstallation,
    RepositoryKitPackage
  }

  alias SddOrchestrator.RepositoryAssessments

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
  alias SddOrchestrator.RepositoryPilots
  alias SddOrchestrator.Specifications.SpecificationLifecycle

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
        "repository-kit-privacy-#{System.unique_integer([:positive])}/store.dets"
      )

    start_supervised!({Local, path: store_path})
    on_exit(fn -> File.rm_rf!(Path.dirname(store_path)) end)

    account = AccountsFixtures.account_fixture()
    workspace = ProjectsFixtures.workspace_fixture(account)
    project = ProjectsFixtures.registered_project(workspace, name: "Kit privacy project")
    repository = git_repository_fixture()

    {:ok, device_workspace} = Devices.establish_workspace()

    {:ok, device_project} =
      Devices.register_project(%{
        name: "Kit privacy device project",
        repository_fingerprint: "kit-privacy-device-repository",
        status: "connected"
      })

    %{
      account: account,
      workspace: workspace,
      project: project,
      repository: repository,
      device_project: device_project,
      device_workspace: device_workspace,
      now: DateTime.utc_now() |> DateTime.truncate(:second)
    }
  end

  describe "deletion coverage [AC-12]" do
    test "deleting the hosted project cascades away its change plan and installation, leaving the global package",
         context do
      %{package: package, plan: plan} = build_plan!(context, default_files())

      assert {:ok, installation} =
               RepositoryKits.apply_plan(hosted(context), context.project.id, plan.id,
                 repository_path: context.repository.path
               )

      assert {:ok, %{project_id: project_id}} =
               SpecificationLifecycle.delete_project(context.workspace, context.project.id)

      assert project_id == context.project.id
      refute Repo.get(RepositoryKitChangePlan, plan.id)
      refute Repo.get(RepositoryKitInstallation, installation.id)
      assert Repo.get(RepositoryKitPackage, package.id)
    end

    test "erase_account/2 removes the account's change plan and installation, leaving the global package",
         context do
      %{package: package, plan: plan} = build_plan!(context, default_files())

      assert {:ok, installation} =
               RepositoryKits.apply_plan(hosted(context), context.project.id, plan.id,
                 repository_path: context.repository.path
               )

      assert {:ok, _result} = Rights.erase_account(context.account.id)

      refute Repo.get(RepositoryKitChangePlan, plan.id)
      refute Repo.get(RepositoryKitInstallation, installation.id)
      assert Repo.get(RepositoryKitPackage, package.id)
    end

    test "deleting a device project removes both its change plan and installation DETS keys together",
         context do
      package = publish_package_fixture()
      plan = device_plan_fixture!(context, package)
      _installation = device_installation_fixture!(context, package, plan)

      assert [_ | _] = Devices.list_repository_kit_change_plans(context.device_project.id)

      assert {:ok, _value} = Devices.get_repository_kit_installation(context.device_project.id)

      assert {:ok,
              %{
                deleted_repository_kit_change_plans: change_plan_deletions,
                deleted_repository_kit_installation: true
              }} = Devices.delete_project(context.device_project.id)

      assert change_plan_deletions == 1

      assert {:error, :not_found} = Devices.get_project(context.device_project.id)

      assert {:error, :not_found} =
               ChangePlanStore.current(
                 device_authority(context),
                 context.device_project.id,
                 context.now
               )

      assert {:error, :not_found} =
               Devices.get_repository_kit_installation(context.device_project.id)

      # No durable hosted copy was ever created for the device-authoritative
      # chain, so hosted deletion coverage has nothing left to prove here.
      assert Repo.aggregate(RepositoryKitChangePlan, :count) == 0
      assert Repo.aggregate(RepositoryKitInstallation, :count) == 0
    end
  end

  describe "retention coverage [AC-12]" do
    test "Retention.prune_all/1 does not need to reach the package, change plan, or installation",
         context do
      %{package: package, plan: plan} = build_plan!(context, default_files())

      assert {:ok, installation} =
               RepositoryKits.apply_plan(hosted(context), context.project.id, plan.id,
                 repository_path: context.repository.path
               )

      # A window far beyond every other governed retention window in the
      # deployment (90-day pinned sessions, 35-day backups, 30-day logs).
      far_future = DateTime.add(context.now, 3650 * 24 * 60 * 60, :second)

      Retention.prune_all(far_future)

      assert Repo.get(RepositoryKitPackage, package.id)
      assert Repo.get(RepositoryKitChangePlan, plan.id)
      assert Repo.get(RepositoryKitInstallation, installation.id)
    end
  end

  describe "no analytics or secondary use, and log redaction [AC-12]" do
    test "the repository-kit domain never calls Logger or inspects its own data" do
      sources =
        (Path.wildcard("lib/sdd_orchestrator/repository_kits/**/*.ex") ++
           ["lib/sdd_orchestrator/repository_kits.ex"])
        |> Enum.map_join("\n", &File.read!/1)

      refute sources =~ "Logger."
      refute sources =~ "IO.inspect"
    end

    test "the package, change plan, and installation tables are not analytics-shaped and carry no secondary use" do
      {:ok, %{rows: rows}} =
        Repo.query(
          "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public'"
        )

      tables = List.flatten(rows)

      for table <-
            ~w(repository_kit_packages repository_kit_change_plans repository_kit_installations) do
        assert table in tables

        refute Regex.match?(
                 ~r/analytic|metric|tracking|telemetry_event|pageview|impression/i,
                 table
               )
      end
    end
  end

  describe "no new processor or cross-border transfer [AC-12]" do
    test "the repository-kit domain only ever shells out to git, never makes an HTTP call" do
      sources =
        (Path.wildcard("lib/sdd_orchestrator/repository_kits/**/*.ex") ++
           ["lib/sdd_orchestrator/repository_kits.ex"])
        |> Enum.map_join("\n", &File.read!/1)

      refute sources =~ ~r/Req\.|HTTPoison|Finch|:httpc|Tesla\./

      for match <- Regex.scan(~r/System\.cmd\(\s*"([^"]+)"/, sources) do
        assert match == ["System.cmd(\"git\"", "git"]
      end
    end
  end

  describe "AC-13 specification-authority invariant" do
    test "nothing in the repository-kit domain reads or writes specification content beyond the approved lifecycle-column read" do
      sources =
        (Path.wildcard("lib/sdd_orchestrator/repository_kits/**/*.ex") ++
           ["lib/sdd_orchestrator/repository_kits.ex"])
        |> Enum.map(fn path -> {path, File.read!(path)} end)

      for {path, source} <- sources do
        refute source =~ "SddOrchestrator.Specifications.",
               "#{path} touches SddOrchestrator.Specifications"

        refute source =~ "SpecificationStore",
               "#{path} touches SpecificationStore"

        # `repository_kits.ex` is the one file allowed to reference
        # `Delivery.Features` at all, and only through the single approved
        # read below.
        if source =~ "Delivery.Features" or source =~ "Features\." do
          assert path == "lib/sdd_orchestrator/repository_kits.ex",
                 "#{path} references Delivery.Features outside the approved read"
        end
      end

      top_level_source = File.read!("lib/sdd_orchestrator/repository_kits.ex")

      # The only call this domain ever makes into the specification/delivery
      # surface: a read of `lifecycle_column` by specification id, never a
      # write, never specification or revision content.
      assert [_] = Regex.scan(~r/Features\.fetch_by_specification\(/, top_level_source)
      refute top_level_source =~ "Features.create"
      refute top_level_source =~ "Features.link_specification"
      refute top_level_source =~ "Features.transition"
    end

    test "the vendored kit test-fixture content carries no specification-shaped content" do
      fixture_source = File.read!("test/support/repository_kit_fixtures.ex")

      refute fixture_source =~ ~r/requirements\.md|design\.md|tasks\.md|## Requirements|## Design/

      for file <- valid_files() do
        refute file.content =~ ~r/requirements\.md|design\.md|tasks\.md/
      end
    end
  end

  ## Plan-building helper (mirrors RepositoryKitsApplyTest's own fixture chain)

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
      title: "Kit privacy pilot specification #{System.unique_integer([:positive])}"
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
  defp device_authority(context), do: {:device, context.device_workspace}

  ## Kit package fixture

  defp publish_kit_package_fixture(attrs_overrides, files) do
    publish_package_fixture(Map.merge(%{scripts: []}, attrs_overrides), files)
  end

  ## Lightweight device store fixtures (mirrors
  ## RepositoryKitsChangePlanStoreTest's/RepositoryKitsInstallationStoreTest's
  ## own `plan_attrs/3`/`installation_value_attrs/2` convention — no
  ## assessment/profile/pilot chain needed for a store-level DETS proof)

  defp device_plan_fixture!(context, package) do
    attrs = %{
      id: Ecto.UUID.generate(),
      project_id: context.device_project.id,
      package_id: package.id,
      package_digest: package.digest,
      profile_version: 1,
      base_commit: String.duplicate("1", 40),
      root: ".",
      repository_provider: "github",
      repository_id: "example/repo",
      target_branch: "sdd-kit/privacy-test-#{System.unique_integer([:positive])}",
      operations: [valid_operation()],
      expires_at: context.now |> DateTime.add(900, :second) |> DateTime.truncate(:microsecond),
      plan_type: "install"
    }

    assert {:ok, plan} = ChangePlanStore.create(device_authority(context), attrs)
    plan
  end

  defp device_installation_fixture!(context, package, plan) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    attrs = %{
      id: Ecto.UUID.generate(),
      project_id: context.device_project.id,
      package_id: package.id,
      plan_id: plan.id,
      package_digest: plan.package_digest,
      profile_version: 1,
      base_commit: String.duplicate("1", 40),
      root: ".",
      repository_provider: "github",
      repository_id: "example/repo",
      branch: plan.target_branch,
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
    }

    assert {:ok, installation} = InstallationStore.create(device_authority(context), attrs)
    installation
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

  ## Throwaway git repository fixture (mirrors RepositoryKitsApplyTest's own)

  defp git_repository_fixture do
    base =
      Path.join(
        System.tmp_dir!(),
        "repository-kit-privacy-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(base)

    git!(base, ["init", "-q"])
    git!(base, ["config", "user.email", "task9@example.invalid"])
    git!(base, ["config", "user.name", "Task 9"])

    write!(base, "AGENTS.md", "# Existing repository instructions\n\nFollow these exactly.\n")
    write!(base, "README.md", "# Example project\n")

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
