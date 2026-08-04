defmodule SddOrchestrator.RepositoryAssessments.WorkerRepositoryAssessmentCacheTest do
  use SddOrchestrator.DataCase, async: true

  alias SddOrchestrator.Repo

  alias SddOrchestrator.RepositoryAssessments.{
    RepositoryAssessment,
    RepositoryAssessmentCacheProvenance,
    RepositoryAssessmentCommand,
    RepositoryAssessmentResult,
    RepositoryExecutionProfileProposalPayload,
    WorkerRepositoryAssessmentCache,
    WorkerRepositoryAssessmentCacheEntry,
    WorkerRepositoryExecutionProfileProposalEnvelope
  }

  @scanner_digest String.duplicate("a", 64)
  @disclosure_digest String.duplicate("b", 64)

  test "a miss scans once and a later exact key reuses only the completed evidence" do
    cache = start_cache()
    first_command = command!()

    second_command =
      command!(%{
        assessment_id: Ecto.UUID.generate(),
        disclosure_digest: String.duplicate("c", 64),
        worker_ref: Ecto.UUID.generate()
      })

    calls = :atomics.new(1, [])

    scanner = fn _repository_path, command, _opts ->
      :atomics.add(calls, 1, 1)
      {:ok, completed_scan(command)}
    end

    assert :miss = WorkerRepositoryAssessmentCache.fetch(cache, first_command)

    assert {:ok, fresh, fresh_provenance} =
             WorkerRepositoryAssessmentCache.scan(
               cache,
               "/worker/repository",
               first_command,
               scanner: scanner
             )

    assert fresh.assessment_id == first_command.assessment_id
    assert fresh_provenance.source == "fresh_scan"
    assert fresh_provenance.cache_stored
    assert :atomics.get(calls, 1) == 1

    scanner_must_not_run = fn _path, _command, _opts ->
      flunk("an exact complete cache hit must not invoke the scanner")
    end

    assert {:ok, reused, cache_provenance} =
             WorkerRepositoryAssessmentCache.scan(
               cache,
               "/worker/repository",
               second_command,
               scanner: scanner_must_not_run
             )

    assert reused.assessment_id == second_command.assessment_id
    assert reused.project_id == second_command.project_id
    assert reused.findings == fresh.findings
    assert reused.structure == fresh.structure
    assert reused.stats == fresh.stats
    assert cache_provenance.source == "complete_cache"
    assert cache_provenance.cache_stored

    assert cache_provenance.cache_key_sha256 == fresh_provenance.cache_key_sha256
    assert cache_provenance.evidence_sha256 == fresh_provenance.evidence_sha256
    assert Regex.match?(~r/\A[0-9a-f]{64}\z/, cache_provenance.cache_key_sha256)
    assert Regex.match?(~r/\A[0-9a-f]{64}\z/, cache_provenance.evidence_sha256)
    assert :atomics.get(calls, 1) == 1

    assert {:ok, rebound_result} = RepositoryAssessmentResult.completed(second_command, reused)
    assert RepositoryAssessmentResult.matches_command?(rebound_result, second_command)

    assert {:ok, ^cache_provenance} =
             RepositoryAssessmentCacheProvenance.validate(
               cache_provenance,
               second_command,
               rebound_result
             )
  end

  test "proposal cache hits keep the payload stable and rebind the current assessment envelope" do
    cache = start_cache()
    first_command = command!()

    second_command =
      command!(%{
        assessment_id: Ecto.UUID.generate(),
        disclosure_digest: String.duplicate("d", 64),
        worker_ref: Ecto.UUID.generate()
      })

    scanner = fn _repository_path, command, _opts ->
      worker_result = completed_scan(command)
      {:ok, worker_result, proposal_payload!(command, worker_result)}
    end

    assert {:ok, fresh, fresh_payload, fresh_envelope, fresh_provenance} =
             WorkerRepositoryAssessmentCache.scan_with_proposal(
               cache,
               "/worker/repository",
               first_command,
               scanner: scanner
             )

    scanner_must_not_run = fn _path, _command, _opts ->
      flunk("an exact complete proposal cache hit must not invoke the scanner")
    end

    assert {:ok, reused, ^fresh_payload, reused_envelope, reused_provenance} =
             WorkerRepositoryAssessmentCache.scan_with_proposal(
               cache,
               "/worker/repository",
               second_command,
               scanner: scanner_must_not_run
             )

    assert fresh.assessment_id == first_command.assessment_id
    assert reused.assessment_id == second_command.assessment_id
    assert fresh_payload.commands == ["mix test"]
    assert fresh_payload.required_checks == ["mix test"]
    assert fresh_payload.payload_digest == reused_envelope.payload_digest
    assert fresh_envelope.assessment_id == first_command.assessment_id
    assert reused_envelope.assessment_id == second_command.assessment_id
    assert fresh_envelope.disclosure_digest == first_command.disclosure_digest
    assert reused_envelope.disclosure_digest == second_command.disclosure_digest
    assert fresh_envelope.worker_ref == first_command.worker_ref
    assert reused_envelope.worker_ref == second_command.worker_ref
    refute fresh_envelope.envelope_digest == reused_envelope.envelope_digest
    refute fresh_envelope.result_sha256 == reused_envelope.result_sha256
    assert fresh_provenance.source == "fresh_scan"
    assert reused_provenance.source == "complete_cache"
    assert fresh_provenance.cache_key_sha256 == reused_provenance.cache_key_sha256
    assert fresh_provenance.evidence_sha256 == reused_provenance.evidence_sha256

    assert {:ok, rebound_result} = RepositoryAssessmentResult.completed(second_command, reused)

    refute WorkerRepositoryExecutionProfileProposalEnvelope.valid_for?(
             fresh_envelope,
             fresh_payload,
             second_command,
             rebound_result
           )

    assert WorkerRepositoryExecutionProfileProposalEnvelope.valid_for?(
             reused_envelope,
             fresh_payload,
             second_command,
             rebound_result
           )

    state_text = cache |> :sys.get_state() |> inspect(limit: :infinity)
    refute state_text =~ first_command.assessment_id
    refute state_text =~ second_command.assessment_id
    refute state_text =~ first_command.disclosure_digest
    refute state_text =~ second_command.disclosure_digest
    refute state_text =~ first_command.worker_ref
    refute state_text =~ second_command.worker_ref
    refute state_text =~ "/worker/repository"
    refute state_text =~ "raw source"
    refute state_text =~ "SECRET"
  end

  test "proposal-aware reuse refuses legacy entries and corrupted payloads" do
    cache = start_cache()
    command = command!()
    worker_result = completed_scan(command)

    assert {:ok, result} = RepositoryAssessmentResult.completed(command, worker_result)
    assert {:ok, _provenance} = WorkerRepositoryAssessmentCache.put(cache, result)
    assert :miss = WorkerRepositoryAssessmentCache.fetch_with_proposal(cache, command)

    payload = proposal_payload!(command, worker_result)
    corrupted = %{payload | commands: ["mix test", "touch /tmp/secret"]}

    assert {:error, :invalid_result} =
             WorkerRepositoryAssessmentCache.put_with_proposal(cache, result, corrupted)

    assert :miss = WorkerRepositoryAssessmentCache.fetch_with_proposal(cache, command)
  end

  test "proposal-aware scans refuse unsuccessful, incomplete, malformed, and mismatched values" do
    cache = start_cache()
    command = command!()
    worker_result = completed_scan(command)
    payload = proposal_payload!(command, worker_result)

    assert {:ok, canceled} = RepositoryAssessmentResult.canceled(command)
    assert {:ok, failed} = RepositoryAssessmentResult.failed(command, :stale_commit)

    assert {:error, :invalid_proposal_payload} =
             RepositoryExecutionProfileProposalPayload.new(canceled, proposal_fields(payload))

    assert {:error, :invalid_proposal_payload} =
             RepositoryExecutionProfileProposalPayload.new(failed, proposal_fields(payload))

    assert {:error, :incomplete_result} =
             WorkerRepositoryAssessmentCache.put_with_proposal(cache, canceled, payload)

    assert {:error, :incomplete_result} =
             WorkerRepositoryAssessmentCache.put_with_proposal(cache, failed, payload)

    for reason <- [:canceled, :time_limit_exceeded] do
      unsuccessful_scanner = fn _path, _command, _opts -> {:error, reason} end

      assert {:error, ^reason} =
               WorkerRepositoryAssessmentCache.scan_with_proposal(
                 cache,
                 "/worker/repository",
                 command,
                 scanner: unsuccessful_scanner
               )
    end

    incomplete_scanner = fn _path, _command, _opts ->
      {:ok, Map.delete(worker_result, :stats), payload}
    end

    assert {:error, :invalid_result} =
             WorkerRepositoryAssessmentCache.scan_with_proposal(
               cache,
               "/worker/repository",
               command,
               scanner: incomplete_scanner
             )

    malformed_scanner = fn _path, _command, _opts -> {:ok, worker_result, %{}} end

    assert {:error, :invalid_proposal_payload} =
             WorkerRepositoryAssessmentCache.scan_with_proposal(
               cache,
               "/worker/repository",
               command,
               scanner: malformed_scanner
             )

    mismatched_command = command!(%{commit: String.duplicate("2", 40)})
    mismatched_result = completed_scan(mismatched_command)
    mismatched_payload = proposal_payload!(mismatched_command, mismatched_result)

    mismatched_scanner = fn _path, _command, _opts ->
      {:ok, worker_result, mismatched_payload}
    end

    assert {:error, :invalid_proposal_payload} =
             WorkerRepositoryAssessmentCache.scan_with_proposal(
               cache,
               "/worker/repository",
               command,
               scanner: mismatched_scanner
             )

    assert :miss = WorkerRepositoryAssessmentCache.fetch_with_proposal(cache, command)
    assert WorkerRepositoryAssessmentCache.stats(cache).entries == 0
  end

  test "cache entry provenance fails closed for an impossible complete-cache storage outcome" do
    command = command!()
    assert {:ok, result} = RepositoryAssessmentResult.completed(command, completed_scan(command))
    assert {:ok, entry} = WorkerRepositoryAssessmentCacheEntry.new(result)

    assert {:error, :invalid_cache_provenance} =
             WorkerRepositoryAssessmentCacheEntry.provenance(
               entry,
               "complete_cache",
               false
             )
  end

  test "project, repository, root, commit, and scanner contract changes are misses" do
    cache = start_cache()
    base = command!()
    put_complete!(cache, base)

    changed_commands = [
      command!(%{project_id: Ecto.UUID.generate()}),
      command!(%{repository_provider: "gitlab"}),
      command!(%{repository_id: "repository-99"}),
      command!(%{root: "apps/api"}),
      command!(%{commit: String.duplicate("2", 40)}),
      command!(%{scanner_contract_digest: String.duplicate("d", 64)}),
      %{base | version: base.version + 1}
    ]

    for changed <- changed_commands do
      assert :miss = WorkerRepositoryAssessmentCache.fetch(cache, changed)
    end

    assert {:hit, _result, _provenance} =
             WorkerRepositoryAssessmentCache.fetch(
               cache,
               command!(%{
                 assessment_id: Ecto.UUID.generate(),
                 disclosure_digest: String.duplicate("e", 64),
                 worker_ref: Ecto.UUID.generate()
               })
             )
  end

  test "every exact limit field participates in the cache key" do
    cache = start_cache()
    base = command!()
    put_complete!(cache, base)

    changed_limits = [
      %{max_paths: base.limits.max_paths - 1},
      %{max_files: base.limits.max_files - 1},
      %{max_total_bytes: base.limits.max_total_bytes - 1},
      %{max_file_bytes: base.limits.max_file_bytes - 1},
      %{timeout_ms: base.limits.timeout_ms - 1}
    ]

    for limit_change <- changed_limits do
      assert :miss =
               WorkerRepositoryAssessmentCache.fetch(
                 cache,
                 command!(%{}, limit_change)
               )
    end
  end

  test "incomplete, failed, and canceled outcomes never enter or become hits" do
    cache = start_cache()
    command = command!()

    assert {:error, :invalid_result} = WorkerRepositoryAssessmentCache.put(cache, %{})

    assert {:ok, canceled} = RepositoryAssessmentResult.canceled(command)
    assert {:error, :incomplete_result} = WorkerRepositoryAssessmentCache.put(cache, canceled)

    assert {:ok, failed} = RepositoryAssessmentResult.failed(command, :stale_commit)
    assert {:error, :incomplete_result} = WorkerRepositoryAssessmentCache.put(cache, failed)

    assert {:ok, completed} =
             RepositoryAssessmentResult.completed(command, completed_scan(command))

    corrupted = %{completed | findings: [%{"content" => "SECRET"}]}
    assert {:error, :invalid_result} = WorkerRepositoryAssessmentCache.put(cache, corrupted)

    incomplete_scanner = fn _path, command, _opts ->
      {:ok, Map.delete(completed_scan(command), :stats)}
    end

    assert {:error, :invalid_result} =
             WorkerRepositoryAssessmentCache.scan(
               cache,
               "/worker/repository",
               command,
               scanner: incomplete_scanner
             )

    for reason <- [:canceled, :stale_commit] do
      unsuccessful_scanner = fn _path, _command, _opts -> {:error, reason} end

      assert {:error, ^reason} =
               WorkerRepositoryAssessmentCache.scan(
                 cache,
                 "/worker/repository",
                 command,
                 scanner: unsuccessful_scanner
               )
    end

    assert :miss = WorkerRepositoryAssessmentCache.fetch(cache, command)
    assert WorkerRepositoryAssessmentCache.stats(cache).entries == 0
  end

  test "entry count and encoded bytes stay bounded with deterministic LRU eviction" do
    first = command!(%{commit: String.duplicate("1", 40)})
    second = command!(%{commit: String.duplicate("2", 40)})
    third = command!(%{commit: String.duplicate("3", 40)})

    count_cache = start_cache(max_entries: 2)
    put_complete!(count_cache, first)
    put_complete!(count_cache, second)

    assert {:hit, _result, _provenance} =
             WorkerRepositoryAssessmentCache.fetch(count_cache, first)

    put_complete!(count_cache, third)

    assert WorkerRepositoryAssessmentCache.stats(count_cache).entries == 2

    assert {:hit, _result, _provenance} =
             WorkerRepositoryAssessmentCache.fetch(count_cache, first)

    assert :miss = WorkerRepositoryAssessmentCache.fetch(count_cache, second)

    assert {:hit, _result, _provenance} =
             WorkerRepositoryAssessmentCache.fetch(count_cache, third)

    {:ok, first_result} =
      RepositoryAssessmentResult.completed(first, completed_scan(first))

    {:ok, first_entry} = WorkerRepositoryAssessmentCacheEntry.new(first_result)
    byte_cache = start_cache(max_entries: 10, max_bytes: first_entry.encoded_bytes * 2)

    put_complete!(byte_cache, first)
    put_complete!(byte_cache, second)
    put_complete!(byte_cache, third)

    byte_stats = WorkerRepositoryAssessmentCache.stats(byte_cache)
    assert byte_stats.entries == 2
    assert byte_stats.encoded_bytes <= byte_stats.max_bytes

    too_small_cache = start_cache(max_bytes: first_entry.encoded_bytes - 1)

    assert {:error, :entry_too_large} =
             WorkerRepositoryAssessmentCache.put(too_small_cache, first_result)

    assert WorkerRepositoryAssessmentCache.stats(too_small_cache).entries == 0
  end

  test "the explicit restart policy discards all memory-only entries" do
    child_id = unique_child_id()
    child_spec = cache_child_spec(child_id, [])
    cache = start_supervised!(child_spec)
    command = command!()
    put_complete!(cache, command)

    assert WorkerRepositoryAssessmentCache.stats(cache).restart_policy == :discard_all
    assert {:hit, _result, _provenance} = WorkerRepositoryAssessmentCache.fetch(cache, command)

    stop_supervised!(child_id)
    restarted = start_supervised!(child_spec)

    assert restarted != cache
    assert :miss = WorkerRepositoryAssessmentCache.fetch(restarted, command)
    assert WorkerRepositoryAssessmentCache.stats(restarted).entries == 0
  end

  test "cache evidence stays worker-local and creates no hosted or authoritative copy" do
    cache = start_cache()

    command =
      command!(%{
        assessment_id: Ecto.UUID.generate(),
        worker_ref: Ecto.UUID.generate(),
        disclosure_digest: String.duplicate("f", 64)
      })

    hosted_count = Repo.aggregate(RepositoryAssessment, :count)
    put_complete!(cache, command)

    assert Repo.aggregate(RepositoryAssessment, :count) == hosted_count

    state_text = cache |> :sys.get_state() |> inspect(limit: :infinity)
    refute state_text =~ command.assessment_id
    refute state_text =~ command.worker_ref
    refute state_text =~ command.disclosure_digest
    refute state_text =~ "/worker/repository"
    refute state_text =~ "raw source"
    refute state_text =~ "SECRET"
  end

  defp start_cache(opts \\ []) do
    child_id = unique_child_id()
    start_supervised!(cache_child_spec(child_id, opts))
  end

  defp cache_child_spec(child_id, opts) do
    Supervisor.child_spec({WorkerRepositoryAssessmentCache, opts}, id: child_id)
  end

  defp unique_child_id do
    {WorkerRepositoryAssessmentCache, System.unique_integer([:positive])}
  end

  defp put_complete!(cache, command) do
    assert {:ok, result} =
             RepositoryAssessmentResult.completed(command, completed_scan(command))

    assert {:ok, provenance} = WorkerRepositoryAssessmentCache.put(cache, result)
    provenance
  end

  defp command!(assessment_overrides \\ %{}, limit_overrides \\ %{}) do
    defaults = %{
      id: Ecto.UUID.generate(),
      project_id: "24d663d2-c771-4d5d-a717-7f8e206ca010",
      repository_provider: "github",
      repository_id: "repository-42",
      root: ".",
      commit: String.duplicate("1", 40),
      scanner_contract_digest: @scanner_digest,
      disclosure_digest: @disclosure_digest,
      worker_ref: Ecto.UUID.generate(),
      state: RepositoryAssessment.pending_state()
    }

    assessment =
      struct!(RepositoryAssessment, %{
        defaults
        | id: Map.get(assessment_overrides, :assessment_id, defaults.id),
          project_id: Map.get(assessment_overrides, :project_id, defaults.project_id),
          repository_provider:
            Map.get(
              assessment_overrides,
              :repository_provider,
              defaults.repository_provider
            ),
          repository_id: Map.get(assessment_overrides, :repository_id, defaults.repository_id),
          root: Map.get(assessment_overrides, :root, defaults.root),
          commit: Map.get(assessment_overrides, :commit, defaults.commit),
          scanner_contract_digest:
            Map.get(
              assessment_overrides,
              :scanner_contract_digest,
              defaults.scanner_contract_digest
            ),
          disclosure_digest:
            Map.get(assessment_overrides, :disclosure_digest, defaults.disclosure_digest),
          worker_ref: Map.get(assessment_overrides, :worker_ref, defaults.worker_ref)
      })

    limits = Map.merge(RepositoryAssessmentCommand.default_limits(), limit_overrides)
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

  defp proposal_payload!(command, worker_result) do
    assert {:ok, result} = RepositoryAssessmentResult.completed(command, worker_result)

    assert {:ok, payload} =
             RepositoryExecutionProfileProposalPayload.new(result, %{
               commands: ["mix test"],
               required_checks: ["mix test"],
               allowed_scope: [command.root],
               gaps: ["missing_repository_instructions"],
               conflicts: [],
               multi_root_blockers: []
             })

    payload
  end

  defp proposal_fields(payload) do
    RepositoryExecutionProfileProposalPayload.proposal_fields(payload)
  end
end
