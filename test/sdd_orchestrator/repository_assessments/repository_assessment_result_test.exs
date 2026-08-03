defmodule SddOrchestrator.RepositoryAssessments.RepositoryAssessmentResultTest do
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Accounts.DeviceWorkspace
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.DeviceStore.Local
  alias SddOrchestrator.Repo
  alias SddOrchestrator.RepositoryAssessments

  alias SddOrchestrator.RepositoryAssessments.{
    AssessmentStore,
    RepositoryAssessment,
    RepositoryAssessmentCommand,
    RepositoryAssessmentResult,
    RepositoryBindingPreparation
  }

  import SddOrchestrator.AccountsFixtures
  import SddOrchestrator.ProjectsFixtures

  @scanner_digest String.duplicate("a", 64)
  @disclosure_digest String.duplicate("b", 64)

  setup do
    store_path =
      Path.join(
        System.tmp_dir!(),
        "repository-assessment-result-#{System.unique_integer([:positive])}/store.dets"
      )

    start_supervised!({Local, path: store_path})
    on_exit(fn -> File.rm_rf!(Path.dirname(store_path)) end)

    {:ok, device_workspace} = Devices.establish_workspace()

    {:ok, device_project} =
      Devices.register_project(%{
        name: "Device terminal assessment",
        repository_fingerprint: "device-terminal-repository",
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

  test "completed results accept only bounded deterministic source-relative metadata", context do
    assessment = pending_assessment(context, :hosted)
    command = command!(assessment)
    scan = completed_scan(command)

    assert {:ok, result} = RepositoryAssessmentResult.completed(command, scan)
    assert result.status == "completed"

    assert result.findings == [
             %{
               "bytes" => 10,
               "category" => "check",
               "line_count" => 2,
               "path" => "Makefile",
               "sha256" => String.duplicate("c", 64)
             }
           ]

    value = RepositoryAssessmentResult.to_value(result)
    assert {:ok, ^result} = RepositoryAssessmentResult.from_value(value)
    assert RepositoryAssessmentResult.matches_command?(result, command)

    assert Map.keys(value) |> Enum.sort() ==
             ~w(assessment_id commit disclosure_digest failure_code findings limits project_id repository root scanner_contract_digest stats status structure version worker_ref)

    refute inspect(value) =~ "/Users/"
    refute inspect(value) =~ "credential"
    refute inspect(value) =~ "raw_diagnostic"
  end

  test "completed results reject unknown fields, unsafe anchors, raw content, and invalid counts",
       context do
    command = context |> pending_assessment(:hosted) |> command!()
    valid = completed_scan(command)

    invalid_results = [
      Map.put(valid, :raw_diagnostic, "worker stack trace"),
      put_in(valid, [:findings, Access.at(0), :path], "/private/repository/Makefile"),
      put_in(valid, [:findings, Access.at(0), :path], "../Makefile"),
      put_in(valid, [:findings, Access.at(0)], %{
        category: "check",
        path: "Makefile",
        bytes: 10,
        sha256: String.duplicate("c", 64),
        line_count: 2,
        content: "SECRET=do-not-store"
      }),
      put_in(valid, [:findings, Access.at(0), :line_count], 11),
      put_in(valid, [:findings, Access.at(0), :bytes], 0),
      put_in(valid, [:stats, :bytes_read], 9),
      Map.put(valid, :findings, [hd(valid.findings) | :improper_tail])
    ]

    for invalid <- invalid_results do
      assert {:error, :invalid_result} = RepositoryAssessmentResult.completed(command, invalid)
    end
  end

  test "completed results enforce max_files, max_paths, and anchor byte bounds", context do
    pending = pending_assessment(context, :hosted)
    default_command = command!(pending)

    file_limits =
      RepositoryAssessmentCommand.default_limits()
      |> Map.put(:max_files, 1)

    path_limits =
      RepositoryAssessmentCommand.default_limits()
      |> Map.put(:max_paths, 1)

    assert {:ok, file_command} = RepositoryAssessmentCommand.new(pending, file_limits)
    assert {:ok, path_command} = RepositoryAssessmentCommand.new(pending, path_limits)

    too_many_files =
      file_command
      |> completed_scan()
      |> Map.put(:findings, [
        finding("Makefile", "c"),
        finding("mix.exs", "d")
      ])

    too_many_paths =
      path_command
      |> completed_scan()
      |> Map.put(:structure, [
        %{path: "lib", kind: "directory"},
        %{path: "test", kind: "directory"}
      ])

    oversized_anchor =
      default_command
      |> completed_scan()
      |> put_in([:findings, Access.at(0), :path], String.duplicate("a", 4_097))

    for {command, invalid} <- [
          {file_command, too_many_files},
          {path_command, too_many_paths},
          {default_command, oversized_anchor}
        ] do
      assert {:error, :invalid_result} = RepositoryAssessmentResult.completed(command, invalid)
    end
  end

  test "canceled and failed outcomes retain no partial evidence and failures are closed",
       context do
    command = context |> pending_assessment(:hosted) |> command!()

    assert {:ok, canceled} = RepositoryAssessmentResult.canceled(command)
    assert canceled.status == "canceled"
    assert canceled.findings == []
    assert canceled.structure == []
    assert canceled.stats == %{}
    assert canceled.failure_code == nil

    for reason <- RepositoryAssessmentResult.failure_codes() do
      assert {:ok, failed} = RepositoryAssessmentResult.failed(command, reason)
      assert failed.status == "failed"
      assert failed.failure_code == reason
      assert failed.findings == []
      assert failed.structure == []
      assert failed.stats == %{}
    end

    assert {:ok, invalid_command} = RepositoryAssessmentResult.failed(command, :invalid_command)
    assert invalid_command.failure_code == "invalid_command"

    assert {:error, :invalid_result} =
             RepositoryAssessmentResult.failed(command, "worker said /Users/me/repository failed")
  end

  test "the aggregate minimized result is rejected before metadata can grow unbounded", context do
    pending = pending_assessment(context, :hosted)

    limits =
      pending.scan_limits
      |> atomize_limits()
      |> Map.put(:max_paths, 10_000)

    assert {:ok, command} = RepositoryAssessmentCommand.new(pending, limits)

    structure =
      for index <- 1..8_000 do
        suffix = index |> Integer.to_string() |> String.pad_leading(5, "0")
        %{path: "#{suffix}-#{String.duplicate("a", 280)}", kind: "directory"}
      end

    scan =
      command
      |> completed_scan()
      |> Map.put(:structure, structure)
      |> put_in([:stats, :discovered_paths], 8_000)

    assert byte_size(:erlang.term_to_binary(scan, [:deterministic])) >
             RepositoryAssessmentResult.max_result_bytes()

    assert {:error, :invalid_result} = RepositoryAssessmentResult.completed(command, scan)
  end

  test "the hosted store atomically persists one completed exact-command result", context do
    pending = put_pending!(context, :hosted)
    command = command!(pending)
    assert {:ok, result} = RepositoryAssessmentResult.completed(command, completed_scan(command))

    assert {:ok, completed} =
             RepositoryAssessments.finish_assessment(
               hosted_authority(context),
               pending.project_id,
               command,
               result,
               now: context.now
             )

    assert completed.state == "completed"
    assert completed.scan_protocol_version == command.version
    assert completed.scan_limits == stringify_limits(command.limits)
    assert completed.findings == result.findings
    assert completed.structure == result.structure
    assert completed.stats == result.stats
    assert completed.failure_code == nil
    assert DateTime.compare(completed.terminal_at, context.now) == :eq

    assert Repo.get!(RepositoryAssessment, pending.id) == completed

    assert {:error, :already_terminal} =
             RepositoryAssessments.finish_assessment(
               hosted_authority(context),
               pending.project_id,
               command,
               result,
               now: DateTime.add(context.now, 1, :second)
             )
  end

  test "a merely valid command with a different limit contract is stale", context do
    pending = put_pending!(context, :hosted)

    different_limits =
      RepositoryAssessmentCommand.default_limits()
      |> Map.update!(:max_files, &(&1 + 1))

    assert {:ok, command} = RepositoryAssessmentCommand.new(pending, different_limits)
    assert {:ok, result} = RepositoryAssessmentResult.canceled(command)

    assert {:error, :stale} =
             RepositoryAssessments.finish_assessment(
               hosted_authority(context),
               pending.project_id,
               command,
               result,
               now: context.now
             )

    assert Repo.get!(RepositoryAssessment, pending.id).state == "pending_scan"
  end

  test "changed repository, root, commit, scanner, disclosure, or worker bindings are stale",
       context do
    binding_fields = [
      repository_provider: "gitlab",
      repository_id: "another-repository",
      root: "apps/api",
      commit: String.duplicate("d", 40),
      scanner_contract_digest: String.duplicate("e", 64),
      disclosure_digest: String.duplicate("f", 64),
      worker_ref: Ecto.UUID.generate()
    ]

    for {field, replacement} <- binding_fields do
      pending = put_pending!(context, :hosted)
      command = command!(pending)
      changed = Map.put(command, field, replacement)
      assert RepositoryAssessmentCommand.valid?(changed)
      assert {:ok, result} = RepositoryAssessmentResult.canceled(changed)

      assert {:error, :stale} =
               RepositoryAssessments.finish_assessment(
                 hosted_authority(context),
                 pending.project_id,
                 changed,
                 result,
                 now: context.now
               )

      assert Repo.get!(RepositoryAssessment, pending.id).state == "pending_scan"
    end
  end

  test "strict stores reject terminal inserts and manually corrupted terminal structs", context do
    pending = put_pending!(context, :hosted)
    command = command!(pending)
    assert {:ok, result} = RepositoryAssessmentResult.completed(command, completed_scan(command))
    assert {:ok, terminal} = RepositoryAssessment.terminal(pending, command, result, context.now)

    terminal_insert = %{terminal | id: Ecto.UUID.generate()}

    assert {:error, :unauthorized} =
             AssessmentStore.put(hosted_authority(context), terminal_insert)

    corrupted = %{terminal | findings: [%{"path" => "/absolute", "raw" => "SECRET"}]}

    assert {:error, :stale} =
             AssessmentStore.transition(hosted_authority(context), pending, corrupted)

    assert Repo.get!(RepositoryAssessment, pending.id).state == "pending_scan"
  end

  test "hosted commit-time authorization and repository binding are rechecked", context do
    pending = put_pending!(context, :hosted)
    command = command!(pending)
    assert {:ok, result} = RepositoryAssessmentResult.canceled(command)

    project = Repo.preload(context.hosted_project, :repository_connection)

    project.repository_connection
    |> Ecto.Changeset.change(state: "disconnected")
    |> Repo.update!()

    assert {:error, :stale} =
             RepositoryAssessments.finish_assessment(
               hosted_authority(context),
               pending.project_id,
               command,
               result,
               now: context.now
             )

    assert Repo.get!(RepositoryAssessment, pending.id).state == "pending_scan"
  end

  test "hosted finish refuses cross-project and non-owner requests", context do
    pending = put_pending!(context, :hosted)
    command = command!(pending)
    assert {:ok, result} = RepositoryAssessmentResult.canceled(command)

    assert {:error, :invalid_result} =
             RepositoryAssessments.finish_assessment(
               hosted_authority(context),
               Ecto.UUID.generate(),
               command,
               result,
               now: context.now
             )

    other_account = account_fixture()

    assert {:error, :not_found} =
             RepositoryAssessments.finish_assessment(
               {:hosted, other_account.id},
               pending.project_id,
               command,
               result,
               now: context.now
             )

    assert Repo.get!(RepositoryAssessment, pending.id).state == "pending_scan"
  end

  test "device-authoritative terminal updates have restart parity and no hosted copy", context do
    hosted_count = Repo.aggregate(RepositoryAssessment, :count)
    pending = put_pending!(context, :device)
    command = command!(pending)
    assert {:ok, result} = RepositoryAssessmentResult.failed(command, :stale_commit)

    assert {:ok, failed} =
             RepositoryAssessments.finish_assessment(
               device_authority(context),
               pending.project_id,
               command,
               result,
               now: context.now
             )

    assert failed.state == "failed"
    assert failed.failure_code == "stale_commit"
    assert failed.findings == []
    assert Repo.aggregate(RepositoryAssessment, :count) == hosted_count

    stop_supervised!(Local)
    start_supervised!({Local, path: context.store_path})
    {:ok, workspace} = Devices.get_workspace()

    assert {:ok, ^failed} =
             AssessmentStore.fetch({:device, workspace}, pending.project_id, pending.id)

    assert {:error, :already_terminal} =
             RepositoryAssessments.finish_assessment(
               {:device, workspace},
               pending.project_id,
               command,
               result,
               now: context.now
             )

    value = RepositoryAssessment.to_value(failed)

    assert {:error, :stale} =
             Devices.transition_repository_assessment(
               pending.project_id,
               pending.id,
               "failed",
               value
             )
  end

  test "device transition refuses foreign workspaces and project bindings", context do
    pending = put_pending!(context, :device)
    command = command!(pending)
    assert {:ok, result} = RepositoryAssessmentResult.canceled(command)

    assert {:error, :not_found} =
             RepositoryAssessments.finish_assessment(
               {:device, %DeviceWorkspace{id: Ecto.UUID.generate()}},
               pending.project_id,
               command,
               result,
               now: context.now
             )

    assert {:ok, stored} =
             AssessmentStore.fetch(
               device_authority(context),
               pending.project_id,
               pending.id
             )

    assert stored.state == "pending_scan"
  end

  test "legacy device pending values normalize to the authoritative default contract", context do
    pending = pending_assessment(context, :device)

    legacy_value =
      pending
      |> RepositoryAssessment.to_value()
      |> Map.drop(
        ~w(scan_protocol_version scan_limits findings structure stats failure_code terminal_at)
      )

    table = :sys.get_state(Local).table
    key = {:repository_assessment, pending.project_id, pending.id}
    :ok = :dets.insert(table, {key, legacy_value})
    :ok = :dets.sync(table)

    assert {:ok, normalized} =
             AssessmentStore.fetch(
               device_authority(context),
               pending.project_id,
               pending.id
             )

    assert normalized.state == "pending_scan"
    assert normalized.scan_protocol_version == RepositoryAssessmentCommand.version()

    assert normalized.scan_limits ==
             stringify_limits(RepositoryAssessmentCommand.default_limits())

    command = command!(normalized)
    assert {:ok, result} = RepositoryAssessmentResult.canceled(command)

    assert {:ok, canceled} =
             RepositoryAssessments.finish_assessment(
               device_authority(context),
               pending.project_id,
               command,
               result,
               now: context.now
             )

    assert canceled.state == "canceled"

    assert {:ok, current_value} =
             Devices.get_repository_assessment(pending.project_id, pending.id)

    assert MapSet.new(Map.keys(current_value)) ==
             MapSet.new(Map.keys(RepositoryAssessment.to_value(canceled)))
  end

  test "the additive migration exposes constrained terminal assessment fields" do
    columns =
      Repo.query!("""
      SELECT column_name, is_nullable
      FROM information_schema.columns
      WHERE table_name = 'repository_assessments'
      """).rows
      |> Map.new(fn [name, nullable] -> {name, nullable} end)

    assert columns["scan_protocol_version"] == "NO"
    assert columns["scan_limits"] == "NO"
    assert columns["findings"] == "YES"
    assert columns["terminal_at"] == "YES"

    constraints =
      Repo.query!("""
      SELECT constraint_name
      FROM information_schema.table_constraints
      WHERE table_name = 'repository_assessments'
      """).rows
      |> Enum.map(&hd/1)

    assert "repository_assessments_state" in constraints
    assert "repository_assessments_scan_contract" in constraints
    assert "repository_assessments_terminal_shape" in constraints
    assert "repository_assessments_failure_code" in constraints
    refute "repository_assessments_pending_state" in constraints
  end

  defp put_pending!(context, authority_kind) do
    pending = pending_assessment(context, authority_kind)
    authority = authority(context, authority_kind)
    assert {:ok, stored} = AssessmentStore.put(authority, pending)
    stored
  end

  defp pending_assessment(context, :hosted) do
    build_pending(
      context.hosted_project.id,
      context.hosted_project.repository_provider,
      context.hosted_project.canonical_repository_id,
      context.now
    )
  end

  defp pending_assessment(context, :device) do
    build_pending(
      context.device_project.id,
      context.device_project.repository_provider,
      context.device_project.repository_id,
      context.now
    )
  end

  defp build_pending(project_id, provider, repository_id, now) do
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
    pending
  end

  defp command!(assessment) do
    limits = atomize_limits(assessment.scan_limits)
    assert {:ok, command} = RepositoryAssessmentCommand.new(assessment, limits)
    command
  end

  defp completed_scan(command) do
    %{
      protocol_version: command.version,
      assessment_id: command.assessment_id,
      project_id: command.project_id,
      repository: %{provider: command.repository_provider, id: command.repository_id},
      root: command.root,
      commit: command.commit,
      scanner_contract_digest: command.scanner_contract_digest,
      status: "completed",
      findings: [
        %{
          category: "check",
          path: "Makefile",
          bytes: 10,
          sha256: String.duplicate("c", 64),
          line_count: 2
        }
      ],
      structure: [%{path: "lib", kind: "directory"}],
      stats: %{discovered_paths: 3, inspected_files: 1, bytes_read: 10}
    }
  end

  defp finding(path, digest_character) do
    %{
      category: "check",
      path: path,
      bytes: 10,
      sha256: String.duplicate(digest_character, 64),
      line_count: 2
    }
  end

  defp authority(context, :hosted), do: hosted_authority(context)
  defp authority(context, :device), do: device_authority(context)
  defp hosted_authority(context), do: {:hosted, context.account.id}
  defp device_authority(context), do: {:device, context.device_workspace}

  defp atomize_limits(limits) do
    %{
      max_paths: limits["max_paths"],
      max_files: limits["max_files"],
      max_total_bytes: limits["max_total_bytes"],
      max_file_bytes: limits["max_file_bytes"],
      timeout_ms: limits["timeout_ms"]
    }
  end

  defp stringify_limits(limits) do
    Map.new(limits, fn {key, value} -> {Atom.to_string(key), value} end)
  end
end
