defmodule SddOrchestrator.RepositoryAssessments.RepositoryExecutionProfileTest do
  use SddOrchestrator.DataCase, async: false

  import Ecto.Query
  import SddOrchestrator.AccountsFixtures
  import SddOrchestrator.ProjectsFixtures

  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.DeviceStore.Local
  alias SddOrchestrator.Repo
  alias SddOrchestrator.RepositoryAssessments

  alias SddOrchestrator.RepositoryAssessments.{
    AssessmentStore,
    ProfileStore,
    RepositoryAssessment,
    RepositoryAssessmentCommand,
    RepositoryAssessmentResult,
    RepositoryBindingPreparation,
    RepositoryExecutionProfile,
    RepositoryExecutionProfileProposal
  }

  @scanner_digest String.duplicate("a", 64)
  @disclosure_digest String.duplicate("b", 64)

  setup do
    store_path =
      Path.join(
        System.tmp_dir!(),
        "repository-execution-profile-#{System.unique_integer([:positive])}/store.dets"
      )

    start_supervised!({Local, path: store_path})
    on_exit(fn -> File.rm_rf!(Path.dirname(store_path)) end)

    {:ok, device_workspace} = Devices.establish_workspace()

    {:ok, device_project} =
      Devices.register_project(%{
        name: "Device execution profile",
        repository_fingerprint: "device-profile-repository",
        status: "connected"
      })

    account = account_fixture()
    workspace = workspace_fixture(account)
    hosted_project = registered_project(workspace)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %{
      account: account,
      device_project: device_project,
      device_workspace: device_workspace,
      hosted_project: hosted_project,
      now: now,
      store_path: store_path
    }
  end

  test "proposal normalization keeps repository instructions authoritative and every blocker visible",
       context do
    assessment = put_completed!(context, :hosted)

    attrs = %{
      commands: [" mix test ", "mix format --check-formatted", "mix test"],
      required_checks: [" mix test "],
      allowed_scope: ["test", "lib", "lib"],
      gaps: [:missing_release_check, "missing_setup_command"],
      conflicts: [:instruction_command_conflict, "safety_conflict"],
      multi_root_blockers: ["apps/web", "apps/api", "apps/api"]
    }

    assert {:ok, proposal} =
             RepositoryAssessments.propose_profile(
               hosted_authority(context),
               assessment.project_id,
               assessment.id,
               attrs
             )

    assert proposal.assessment_id == assessment.id
    assert proposal.root == assessment.root
    assert proposal.base_revision == assessment.commit

    assert proposal.instruction_precedence == [
             %{
               "authority" => "repository",
               "category" => "instruction",
               "path" => "apps/api/AGENTS.md"
             },
             %{
               "authority" => "repository",
               "category" => "instruction",
               "path" => "AGENTS.md"
             },
             %{
               "authority" => "repository",
               "category" => "contribution",
               "path" => "CONTRIBUTING.md"
             }
           ]

    assert proposal.commands == ["mix format --check-formatted", "mix test"]
    assert proposal.required_checks == ["mix test"]
    assert proposal.allowed_scope == ["lib", "test"]
    assert proposal.gaps == ["missing_release_check", "missing_setup_command"]
    assert proposal.conflicts == ["instruction_command_conflict", "safety_conflict"]
    assert proposal.multi_root_blockers == ["apps/api", "apps/web"]
    assert RepositoryExecutionProfileProposal.matches_assessment?(proposal, assessment)

    value = RepositoryExecutionProfileProposal.to_value(proposal)
    assert {:ok, ^proposal} = RepositoryExecutionProfileProposal.from_value(value)

    refute inspect(value) =~ "/Users/"
    refute inspect(value) =~ "credential"
    refute inspect(value) =~ "raw_diagnostic"
    refute inspect(value) =~ "source_content"
  end

  test "proposal input cannot replace the assessment binding, weaken checks, or escape scope",
       context do
    assessment = put_completed!(context, :hosted)
    attrs = proposal_attrs()

    invalid = [
      Map.put(attrs, :base_revision, String.duplicate("f", 40)),
      %{attrs | required_checks: ["mix test --only invented"]},
      %{attrs | allowed_scope: ["../outside"]},
      %{attrs | commands: ["mix test\nrm -rf unsafe"]},
      %{attrs | commands: ["TOKEN=do-not-store mix test"]},
      %{attrs | commands: ["/private/repository/bin/test"]},
      %{attrs | commands: ["MIX_DEPS_PATH=/Users/alice/deps mix test"]},
      %{attrs | commands: ["mix test --config=/private/config"]},
      %{attrs | commands: [~s(mix test --config="/private/config")]},
      %{attrs | commands: [~S(mix test --config='C:\private\config')]},
      %{attrs | commands: [~S(cmd /c "C:\private\bin\test.bat")]},
      %{attrs | conflicts: ["free form conflict detail"]},
      %{attrs | multi_root_blockers: ["/absolute/root"]}
    ]

    for input <- invalid do
      assert {:error, :invalid_proposal} =
               RepositoryAssessments.propose_profile(
                 hosted_authority(context),
                 assessment.project_id,
                 assessment.id,
                 input
               )
    end

    assert ProfileStore.count(hosted_authority(context), assessment.project_id) == 0
  end

  test "hosted owner approval is idempotent and appends distinct immutable versions", context do
    assessment = put_completed!(context, :hosted)
    proposal = propose!(context, :hosted, assessment, proposal_attrs())

    assert {:ok, first} =
             RepositoryAssessments.approve_profile(
               hosted_authority(context),
               assessment.project_id,
               proposal,
               now: context.now
             )

    assert first.version == 1
    assert first.assessment_id == assessment.id
    assert first.base_revision == assessment.commit
    assert first.approval_actor_ref == context.account.id
    assert RepositoryExecutionProfile.strict?(first)

    assert {:ok, replayed} =
             RepositoryAssessments.approve_profile(
               hosted_authority(context),
               assessment.project_id,
               proposal,
               now: DateTime.add(context.now, 10, :second)
             )

    assert replayed.id == first.id
    assert replayed.approved_at == first.approved_at

    second_attrs =
      proposal_attrs()
      |> Map.update!(:commands, &(&1 ++ ["mix credo --strict"]))
      |> Map.update!(:required_checks, &(&1 ++ ["mix credo --strict"]))
      |> Map.put(:gaps, [])

    second_proposal = propose!(context, :hosted, assessment, second_attrs)

    assert {:ok, second} =
             RepositoryAssessments.approve_profile(
               hosted_authority(context),
               assessment.project_id,
               second_proposal,
               now: DateTime.add(context.now, 20, :second)
             )

    assert second.version == 2
    assert second.id != first.id

    assert Enum.map(ProfileStore.list(hosted_authority(context), assessment.project_id), & &1.id) ==
             [first.id, second.id]

    assert Repo.aggregate(RepositoryExecutionProfile, :count) == 2
    refute function_exported?(RepositoryExecutionProfile, :update_changeset, 2)
  end

  test "the hosted database rejects mutation of an approved version", context do
    assessment = put_completed!(context, :hosted)
    proposal = propose!(context, :hosted, assessment, proposal_attrs())

    assert {:ok, profile} =
             RepositoryAssessments.approve_profile(
               hosted_authority(context),
               assessment.project_id,
               proposal,
               now: context.now
             )

    assert_raise Postgrex.Error, ~r/immutable/, fn ->
      Repo.update_all(
        from(current in RepositoryExecutionProfile, where: current.id == ^profile.id),
        set: [commands: ["mix test --changed"]]
      )
    end
  end

  test "device approval has restart parity, append-only versions, and no hosted copy", context do
    hosted_count = Repo.aggregate(RepositoryExecutionProfile, :count)
    assessment = put_completed!(context, :device)
    first_proposal = propose!(context, :device, assessment, proposal_attrs())

    assert {:ok, first} =
             RepositoryAssessments.approve_profile(
               device_authority(context),
               assessment.project_id,
               first_proposal,
               now: context.now
             )

    second_proposal =
      propose!(
        context,
        :device,
        assessment,
        proposal_attrs(%{conflicts: ["instruction_scope_conflict"]})
      )

    assert {:ok, second} =
             RepositoryAssessments.approve_profile(
               device_authority(context),
               assessment.project_id,
               second_proposal,
               now: DateTime.add(context.now, 1, :second)
             )

    assert [first.version, second.version] == [1, 2]
    assert Repo.aggregate(RepositoryExecutionProfile, :count) == hosted_count

    stop_supervised!(Local)
    start_supervised!({Local, path: context.store_path})
    {:ok, workspace} = Devices.get_workspace()

    assert Enum.map(ProfileStore.list({:device, workspace}, assessment.project_id), & &1.id) == [
             first.id,
             second.id
           ]

    assert Repo.aggregate(RepositoryExecutionProfile, :count) == hosted_count
    refute function_exported?(Devices, :update_repository_execution_profile, 3)
  end

  test "only the owner can approve or reject and rejection appends no version", context do
    assessment = put_completed!(context, :hosted)
    proposal = propose!(context, :hosted, assessment, proposal_attrs())
    other_account = account_fixture()

    assert {:error, :unauthorized} =
             RepositoryAssessments.approve_profile(
               {:hosted, other_account.id},
               assessment.project_id,
               proposal,
               now: context.now
             )

    assert {:error, :unauthorized} =
             RepositoryAssessments.reject_profile(
               {:hosted, other_account.id},
               assessment.project_id,
               proposal,
               now: context.now
             )

    assert :ok =
             RepositoryAssessments.reject_profile(
               hosted_authority(context),
               assessment.project_id,
               proposal,
               now: context.now
             )

    assert ProfileStore.count(hosted_authority(context), assessment.project_id) == 0
  end

  test "pending, unsuccessful, changed, and cross-project assessments are refused", context do
    completed = put_completed!(context, :hosted)
    proposal = propose!(context, :hosted, completed, proposal_attrs())
    pending = put_pending!(context, :hosted)
    canceled = put_terminal!(context, :hosted, "canceled")

    for assessment <- [pending, canceled] do
      assert {:error, :stale_assessment} =
               RepositoryAssessments.propose_profile(
                 hosted_authority(context),
                 assessment.project_id,
                 assessment.id,
                 proposal_attrs()
               )
    end

    _newer_pending = put_pending!(context, :hosted, DateTime.add(context.now, 1, :second))

    assert {:error, :stale_assessment} =
             RepositoryAssessments.approve_profile(
               hosted_authority(context),
               completed.project_id,
               proposal,
               now: context.now
             )

    other_account = account_fixture()
    other_project = other_account |> workspace_fixture() |> registered_project()

    assert {:error, :unauthorized} =
             RepositoryAssessments.approve_profile(
               hosted_authority(context),
               other_project.id,
               proposal,
               now: context.now
             )

    assert ProfileStore.count(hosted_authority(context), completed.project_id) == 0
    assert ProfileStore.count({:hosted, other_account.id}, other_project.id) == 0
  end

  test "the migration exposes version, binding, uniqueness, and immutability constraints" do
    columns =
      Repo.query!("""
      SELECT column_name, data_type, is_nullable
      FROM information_schema.columns
      WHERE table_name = 'repository_execution_profiles'
      """).rows
      |> Map.new(fn [name, type, nullable] -> {name, {type, nullable}} end)

    assert columns["project_id"] == {"uuid", "NO"}
    assert columns["assessment_id"] == {"uuid", "NO"}
    assert columns["version"] == {"integer", "NO"}
    assert columns["root"] == {"text", "NO"}
    assert columns["instruction_precedence"] == {"ARRAY", "NO"}
    assert columns["commands"] == {"ARRAY", "NO"}
    assert columns["approved_at"] == {"timestamp without time zone", "NO"}
    refute Map.has_key?(columns, "updated_at")

    constraints =
      Repo.query!("""
      SELECT constraint_name
      FROM information_schema.table_constraints
      WHERE table_name = 'repository_execution_profiles'
      """).rows
      |> Enum.map(&hd/1)

    assert "repository_execution_profiles_version_positive" in constraints
    assert "repository_execution_profiles_commit_shape" in constraints
    assert "repository_execution_profiles_digest_shape" in constraints

    indexes =
      Repo.query!("""
      SELECT indexname
      FROM pg_indexes
      WHERE tablename = 'repository_execution_profiles'
      """).rows
      |> Enum.map(&hd/1)

    assert "repository_execution_profiles_project_version_index" in indexes
    assert "repository_execution_profiles_project_assessment_proposal_index" in indexes

    assert Repo.query!("""
           SELECT 1 FROM pg_trigger
           WHERE tgname = 'repository_execution_profiles_immutable' AND NOT tgisinternal
           """).num_rows == 1
  end

  defp propose!(context, kind, assessment, attrs) do
    assert {:ok, proposal} =
             RepositoryAssessments.propose_profile(
               authority(context, kind),
               assessment.project_id,
               assessment.id,
               attrs
             )

    proposal
  end

  defp proposal_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        commands: ["mix test", "mix format --check-formatted"],
        required_checks: ["mix test"],
        allowed_scope: ["lib", "test"],
        gaps: ["missing_release_check"],
        conflicts: [],
        multi_root_blockers: ["apps/api", "apps/web"]
      },
      overrides
    )
  end

  defp put_completed!(context, kind) do
    put_terminal!(context, kind, "completed")
  end

  defp put_terminal!(context, kind, status) do
    pending = put_pending!(context, kind)
    command = command!(pending)

    result =
      case status do
        "completed" ->
          assert {:ok, result} =
                   RepositoryAssessmentResult.completed(command, completed_scan(command))

          result

        "canceled" ->
          assert {:ok, result} = RepositoryAssessmentResult.canceled(command)
          result
      end

    assert {:ok, terminal} =
             RepositoryAssessments.finish_assessment(
               authority(context, kind),
               pending.project_id,
               command,
               result,
               now: context.now
             )

    terminal
  end

  defp put_pending!(context, kind, override_now \\ nil) do
    now = override_now || context.now

    case kind do
      :hosted ->
        put_pending(
          hosted_authority(context),
          context.hosted_project.id,
          context.hosted_project.repository_provider,
          context.hosted_project.canonical_repository_id,
          now
        )

      :device ->
        put_pending(
          device_authority(context),
          context.device_project.id,
          context.device_project.repository_provider,
          context.device_project.repository_id,
          now
        )
    end
  end

  defp put_pending(authority, project_id, provider, repository_id, now) do
    assert {:ok, preparation} =
             RepositoryBindingPreparation.new(%{
               project_id: project_id,
               repository_provider: provider,
               repository_id: repository_id,
               root: ".",
               commit: String.duplicate("1", 40),
               scanner_contract_digest: @scanner_digest,
               disclosure_digest: @disclosure_digest,
               worker_ref: Ecto.UUID.generate(),
               nonce: Ecto.UUID.generate(),
               issued_at: now,
               expires_at: DateTime.add(now, 120, :second)
             })

    assert {:ok, pending} = RepositoryAssessment.pending(preparation, now)
    assert {:ok, stored} = AssessmentStore.put(authority, pending)
    stored
  end

  defp command!(assessment) do
    limits = %{
      max_paths: assessment.scan_limits["max_paths"],
      max_files: assessment.scan_limits["max_files"],
      max_total_bytes: assessment.scan_limits["max_total_bytes"],
      max_file_bytes: assessment.scan_limits["max_file_bytes"],
      timeout_ms: assessment.scan_limits["timeout_ms"]
    }

    assert {:ok, command} = RepositoryAssessmentCommand.new(assessment, limits)
    command
  end

  defp completed_scan(command) do
    paths = [
      {"AGENTS.md", "instruction", "1"},
      {"CONTRIBUTING.md", "contribution", "2"},
      {"Makefile", "check", "3"},
      {"apps/api/AGENTS.md", "instruction", "4"},
      {"apps/api/mix.exs", "manifest", "5"},
      {"apps/web/package.json", "manifest", "6"}
    ]

    findings =
      Enum.map(paths, fn {path, category, digest_character} ->
        %{
          category: category,
          path: path,
          bytes: 10,
          sha256: String.duplicate(digest_character, 64),
          line_count: 2
        }
      end)

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
      structure: [
        %{path: "apps", kind: "directory"},
        %{path: "apps/api", kind: "directory"},
        %{path: "apps/web", kind: "directory"},
        %{path: "lib", kind: "directory"},
        %{path: "test", kind: "directory"}
      ],
      stats: %{discovered_paths: 12, inspected_files: 6, bytes_read: 60}
    }
  end

  defp authority(context, :hosted), do: hosted_authority(context)
  defp authority(context, :device), do: device_authority(context)
  defp hosted_authority(context), do: {:hosted, context.account.id}
  defp device_authority(context), do: {:device, context.device_workspace}
end
