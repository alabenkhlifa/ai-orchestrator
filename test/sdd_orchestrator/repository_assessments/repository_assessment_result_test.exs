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
    RepositoryAssessmentCacheProvenance,
    RepositoryAssessmentCommand,
    RepositoryAssessmentResult,
    RepositoryBindingPreparation,
    RepositoryExecutionProfileProposalPayload,
    WorkerRepositoryExecutionProfileProposalEnvelope
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

  test "cache provenance is exact, minimized, and canonically bound to command and evidence",
       context do
    command = context |> pending_assessment(:hosted) |> command!()
    assert {:ok, result} = RepositoryAssessmentResult.completed(command, completed_scan(command))

    fresh = provenance!(command, result)
    assert {:ok, ^fresh} = RepositoryAssessmentCacheProvenance.validate(fresh, command, result)

    assert RepositoryAssessmentCacheProvenance.to_value(fresh) == %{
             "source" => "fresh_scan",
             "cache_key_sha256" => fresh.cache_key_sha256,
             "evidence_sha256" => fresh.evidence_sha256,
             "cache_stored" => true
           }

    assert {:ok, not_stored} =
             RepositoryAssessmentCacheProvenance.new(%{
               source: "fresh_scan",
               cache_key_sha256: fresh.cache_key_sha256,
               evidence_sha256: fresh.evidence_sha256,
               cache_stored: false
             })

    assert {:ok, cached} =
             RepositoryAssessmentCacheProvenance.new(%{
               source: "complete_cache",
               cache_key_sha256: fresh.cache_key_sha256,
               evidence_sha256: fresh.evidence_sha256,
               cache_stored: true
             })

    assert {:ok, ^not_stored} =
             RepositoryAssessmentCacheProvenance.validate(not_stored, command, result)

    assert {:ok, ^cached} =
             RepositoryAssessmentCacheProvenance.validate(cached, command, result)

    invalid_shapes = [
      Map.from_struct(fresh) |> Map.delete(:source),
      Map.from_struct(fresh) |> Map.put(:source, "inferred_cache"),
      Map.from_struct(fresh) |> Map.put(:cache_key_sha256, String.upcase(fresh.cache_key_sha256)),
      Map.from_struct(fresh) |> Map.put(:evidence_sha256, String.duplicate("g", 64)),
      Map.from_struct(fresh) |> Map.put(:raw_cache_entry, %{source: "SECRET"}),
      %{Map.from_struct(cached) | cache_stored: false}
    ]

    for invalid <- invalid_shapes do
      assert {:error, :invalid_cache_provenance} =
               RepositoryAssessmentCacheProvenance.new(invalid)
    end

    changed_command = %{command | commit: String.duplicate("2", 40)}

    assert {:ok, changed_result} =
             RepositoryAssessmentResult.completed(
               changed_command,
               completed_scan(changed_command)
             )

    assert {:error, :invalid_cache_provenance} =
             RepositoryAssessmentCacheProvenance.validate(fresh, changed_command, changed_result)

    changed_evidence =
      result
      |> Map.update!(:findings, fn [finding] ->
        [%{finding | "sha256" => String.duplicate("d", 64)}]
      end)

    assert RepositoryAssessmentResult.valid?(changed_evidence)

    assert {:error, :invalid_cache_provenance} =
             RepositoryAssessmentCacheProvenance.validate(fresh, command, changed_evidence)

    serialized = inspect(RepositoryAssessmentCacheProvenance.to_value(fresh), limit: :infinity)
    refute serialized =~ "/Users/"
    refute serialized =~ "repository index"
    refute serialized =~ "source_content"
    refute serialized =~ "credential"
    refute serialized =~ "diagnostic"
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
               provenance!(command, result),
               now: context.now,
               proposal_envelope: envelope!(command, result)
             )

    assert completed.state == "completed"
    assert completed.scan_protocol_version == command.version
    assert completed.scan_limits == stringify_limits(command.limits)
    assert completed.findings == result.findings
    assert completed.structure == result.structure
    assert completed.stats == result.stats
    assert completed.failure_code == nil
    assert completed.cache_source == "fresh_scan"
    assert completed.cache_stored
    assert Regex.match?(~r/\A[0-9a-f]{64}\z/, completed.cache_key_sha256)
    assert Regex.match?(~r/\A[0-9a-f]{64}\z/, completed.evidence_sha256)
    assert DateTime.compare(completed.terminal_at, context.now) == :eq

    completed_value = RepositoryAssessment.to_value(completed)

    assert Map.take(
             completed_value,
             ~w(cache_source cache_key_sha256 evidence_sha256 cache_stored)
           ) ==
             %{
               "cache_source" => "fresh_scan",
               "cache_key_sha256" => completed.cache_key_sha256,
               "evidence_sha256" => completed.evidence_sha256,
               "cache_stored" => true
             }

    refute inspect(completed_value, limit: :infinity) =~ "raw_cache_entry"
    refute inspect(completed_value, limit: :infinity) =~ "repository_index"
    refute inspect(completed_value, limit: :infinity) =~ "source_content"
    refute inspect(completed_value, limit: :infinity) =~ "credential"
    refute inspect(completed_value, limit: :infinity) =~ "/Users/"
    refute inspect(completed_value, limit: :infinity) =~ "diagnostic"

    assert Repo.get!(RepositoryAssessment, pending.id) == completed

    assert {:error, :already_terminal} =
             RepositoryAssessments.finish_assessment(
               hosted_authority(context),
               pending.project_id,
               command,
               result,
               provenance!(command, result),
               now: DateTime.add(context.now, 1, :second)
             )
  end

  test "completed finishes reject missing, malformed, inferred, and mismatched provenance",
       context do
    pending = put_pending!(context, :hosted)
    command = command!(pending)
    assert {:ok, result} = RepositoryAssessmentResult.completed(command, completed_scan(command))
    valid = provenance!(command, result)

    invalid_values = [
      nil,
      Map.from_struct(valid) |> Map.delete(:source),
      Map.from_struct(valid) |> Map.put(:source, "unknown"),
      Map.from_struct(valid) |> Map.put(:cache_key_sha256, String.duplicate("0", 64)),
      Map.from_struct(valid) |> Map.put(:evidence_sha256, String.duplicate("1", 64)),
      Map.from_struct(valid) |> Map.put(:raw_diagnostic, "worker stack trace")
    ]

    for invalid <- invalid_values do
      assert {:error, :invalid_cache_provenance} =
               RepositoryAssessments.finish_assessment(
                 hosted_authority(context),
                 pending.project_id,
                 command,
                 result,
                 invalid,
                 now: context.now
               )

      assert Repo.get!(RepositoryAssessment, pending.id).state == "pending_scan"
    end

    mismatched_command = %{command | commit: String.duplicate("2", 40)}

    assert {:ok, mismatched_result} =
             RepositoryAssessmentResult.completed(
               mismatched_command,
               completed_scan(mismatched_command)
             )

    mismatched = provenance!(mismatched_command, mismatched_result)

    assert {:error, :invalid_cache_provenance} =
             RepositoryAssessments.finish_assessment(
               hosted_authority(context),
               pending.project_id,
               command,
               result,
               mismatched,
               now: context.now
             )

    assert Repo.get!(RepositoryAssessment, pending.id).state == "pending_scan"
  end

  test "fresh evidence may complete when the worker could not retain its cache entry", context do
    pending = put_pending!(context, :hosted)
    command = command!(pending)
    assert {:ok, result} = RepositoryAssessmentResult.completed(command, completed_scan(command))
    provenance = provenance!(command, result, %{cache_stored: false})

    assert {:ok, completed} =
             RepositoryAssessments.finish_assessment(
               hosted_authority(context),
               pending.project_id,
               command,
               result,
               provenance,
               now: context.now,
               proposal_envelope: envelope!(command, result)
             )

    assert completed.cache_source == "fresh_scan"
    refute completed.cache_stored
    refute Repo.get!(RepositoryAssessment, pending.id).cache_stored
  end

  test "canceled and failed finishes reject provenance and persist none", context do
    for status <- [:canceled, :failed] do
      pending = put_pending!(context, :hosted)
      command = command!(pending)

      assert {:ok, completed_result} =
               RepositoryAssessmentResult.completed(command, completed_scan(command))

      provenance = provenance!(command, completed_result)

      result =
        case status do
          :canceled -> elem(RepositoryAssessmentResult.canceled(command), 1)
          :failed -> elem(RepositoryAssessmentResult.failed(command, :stale_commit), 1)
        end

      assert {:error, :invalid_cache_provenance} =
               RepositoryAssessments.finish_assessment(
                 hosted_authority(context),
                 pending.project_id,
                 command,
                 result,
                 provenance,
                 now: context.now
               )

      assert {:ok, terminal} =
               RepositoryAssessments.finish_assessment(
                 hosted_authority(context),
                 pending.project_id,
                 command,
                 result,
                 now: context.now
               )

      assert terminal.state == Atom.to_string(status)

      assert Enum.all?(~w(cache_source cache_key_sha256 evidence_sha256 cache_stored), fn field ->
               is_nil(Map.fetch!(RepositoryAssessment.to_value(terminal), field))
             end)
    end
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

    assert {:ok, terminal} =
             RepositoryAssessment.terminal(
               pending,
               command,
               result,
               provenance!(command, result),
               context.now
             )

    invalid_result = %{result | findings: [%{"raw_content" => "SECRET"}]}

    assert {:error, :invalid_result} =
             RepositoryAssessment.terminal(
               pending,
               command,
               invalid_result,
               provenance!(command, result),
               context.now
             )

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

  test "device-authoritative complete-cache provenance survives restart with hosted parity",
       context do
    hosted_count = Repo.aggregate(RepositoryAssessment, :count)
    pending = put_pending!(context, :device)
    command = command!(pending)
    assert {:ok, result} = RepositoryAssessmentResult.completed(command, completed_scan(command))

    provenance =
      provenance!(command, result, %{source: "complete_cache", cache_stored: true})

    assert {:ok, completed} =
             RepositoryAssessments.finish_assessment(
               device_authority(context),
               pending.project_id,
               command,
               result,
               provenance,
               now: context.now,
               proposal_envelope: envelope!(command, result)
             )

    assert completed.cache_source == "complete_cache"
    assert completed.cache_key_sha256 == provenance.cache_key_sha256
    assert completed.evidence_sha256 == provenance.evidence_sha256
    assert completed.cache_stored
    assert Repo.aggregate(RepositoryAssessment, :count) == hosted_count

    stop_supervised!(Local)
    start_supervised!({Local, path: context.store_path})
    {:ok, workspace} = Devices.get_workspace()

    assert {:ok, restarted} =
             AssessmentStore.fetch({:device, workspace}, pending.project_id, pending.id)

    assert restarted == completed
    assert RepositoryAssessment.cache_provenance_complete?(restarted)
    assert Repo.aggregate(RepositoryAssessment, :count) == hosted_count
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
        ~w(scan_protocol_version scan_limits findings structure stats failure_code terminal_at cache_source cache_key_sha256 evidence_sha256 cache_stored)
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
    assert columns["cache_source"] == "YES"
    assert columns["cache_key_sha256"] == "YES"
    assert columns["evidence_sha256"] == "YES"
    assert columns["cache_stored"] == "YES"

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
    assert "repository_assessments_cache_provenance_all_or_none" in constraints
    assert "repository_assessments_cache_source" in constraints
    assert "repository_assessments_cache_digest_shape" in constraints
    assert "repository_assessments_complete_cache_stored" in constraints
    assert "repository_assessments_cache_provenance_completed_only" in constraints
    refute "repository_assessments_pending_state" in constraints
  end

  test "database constraints reject partial, malformed, impossible, and unsuccessful provenance",
       context do
    completed_pending = put_pending!(context, :hosted)
    command = command!(completed_pending)
    assert {:ok, result} = RepositoryAssessmentResult.completed(command, completed_scan(command))

    assert {:ok, _completed} =
             RepositoryAssessments.finish_assessment(
               hosted_authority(context),
               completed_pending.project_id,
               command,
               result,
               provenance!(command, result),
               now: context.now,
               proposal_envelope: envelope!(command, result)
             )

    pending = put_pending!(context, :hosted)

    constraint_updates = [
      {"cache_key_sha256 = NULL", completed_pending.id},
      {"cache_source = 'unknown'", completed_pending.id},
      {"cache_key_sha256 = 'ABC'", completed_pending.id},
      {"cache_source = 'complete_cache', cache_stored = FALSE", completed_pending.id},
      {"cache_source = 'fresh_scan', cache_key_sha256 = '#{String.duplicate("a", 64)}', evidence_sha256 = '#{String.duplicate("b", 64)}', cache_stored = TRUE",
       pending.id}
    ]

    for {set_clause, assessment_id} <- constraint_updates do
      assert_raise Postgrex.Error, fn ->
        Repo.transaction(
          fn ->
            Repo.query!(
              "UPDATE repository_assessments SET #{set_clause} WHERE id = $1",
              [Ecto.UUID.dump!(assessment_id)]
            )
          end,
          mode: :savepoint
        )
      end
    end
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

  defp envelope!(command, result) do
    assert {:ok, payload} =
             RepositoryExecutionProfileProposalPayload.new(result, %{
               commands: ["mix test"],
               required_checks: ["mix test"],
               allowed_scope: [command.root],
               gaps: ["missing_repository_instructions"],
               conflicts: [],
               multi_root_blockers: []
             })

    assert {:ok, envelope} =
             WorkerRepositoryExecutionProfileProposalEnvelope.new(payload, command, result)

    envelope
  end

  defp provenance!(command, result, overrides \\ %{}) do
    {:ok, cache_key_sha256} = RepositoryAssessmentCacheProvenance.cache_key_sha256(command)
    {:ok, evidence_sha256} = RepositoryAssessmentCacheProvenance.evidence_sha256(result)

    attrs =
      Map.merge(
        %{
          source: "fresh_scan",
          cache_key_sha256: cache_key_sha256,
          evidence_sha256: evidence_sha256,
          cache_stored: true
        },
        overrides
      )

    assert {:ok, provenance} = RepositoryAssessmentCacheProvenance.new(attrs)
    provenance
  end
end
