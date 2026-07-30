defmodule SddOrchestrator.Delivery.VerificationCompletionTest do
  @moduledoc """
  Proof for the same-commit completion gate (Task 30).

  One promise is being pinned above all others: a run claims success only when
  every check its own contract required has a current, passing, command-derived
  result against the one commit being offered for review, on the run's branch,
  at the attempt's revision. Everything else — a failed check, an absent one, a
  result belonging to a different or an earlier commit, a mismatched identity —
  refuses, and the refusal names what was wrong so the missing or failed
  evidence stays visible.

  The sharpest case is the empty one. An attempt whose contract snapshot is
  empty knows of no checks at all, and a gate that read that as "everything
  required passed" would hand a worker exactly the unsupported completion claim
  this whole path exists to refuse. It is proved directly.

  Every behavioural test runs against both storage authorities, because
  `specs/05` forbids keeping a device-authoritative project's records in the
  hosted database and two implementations are only safe once they answer the
  same way.
  """
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Accounts.DeviceWorkspace

  alias SddOrchestrator.Delivery.{
    DeliveryStore,
    EventIngestion,
    EvidenceIngestion,
    Feature,
    RunAttempt,
    VerificationCompletion,
    WorkerProtocol
  }

  alias SddOrchestrator.Delivery.VerificationCompletion.Verdict
  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.DeviceStore.Local
  alias SddOrchestrator.Repo

  @commit "a1b2c3d4e5f6a7b8c9d0"
  @later_commit "b2b2b2b2b2b2b2b2b2b2"
  @contract ["mix test", "mix credo"]
  @migration_version 20_260_730_010_000

  setup context do
    hosted = DeliveryFixtures.delivery_project_fixture()
    feature = DeliveryFixtures.feature_fixture(hosted.project, hosted.account)

    path =
      Path.join(System.tmp_dir!(), "verification-#{System.unique_integer([:positive])}.dets")

    start_supervised!({Local, path: path})
    on_exit(fn -> File.rm_rf(path) end)

    {:ok, device_workspace} = Devices.establish_workspace()

    authority =
      case context[:authority] do
        :device -> %DeviceWorkspace{id: device_workspace.id}
        _hosted -> hosted.workspace
      end

    {:ok, %{run: run, attempt: attempt}} =
      DeliveryStore.commit(
        authority,
        hosted.project.id,
        run_steps(hosted.project, feature, @contract)
      )

    %{
      authority: authority,
      account: hosted.account,
      project: hosted.project,
      feature: feature,
      run: run,
      attempt: attempt
    }
  end

  # Every behaviour below runs twice: once against PostgreSQL and once against
  # the worker-owned device store.
  for authority <- [:hosted, :device] do
    describe "a complete set of proof (#{authority})" do
      @describetag authority: authority

      test "every contracted check passing on the exact commit is verified [AC-19]", context do
        pass_all(context)

        assert {:ok, results} = complete(context, sequence: 10)

        assert results.applied?
        assert %Verdict{outcome: :verified, reason: nil} = results.verdict
        assert Verdict.verified?(results.verdict)
        assert Enum.sort(results.verdict.passed) == Enum.sort(@contract)
        assert results.verdict.failed == []
        assert results.verdict.missing == []
        assert results.verdict.unsupported == []
        assert results.verdict.commit_sha == @commit
        assert results.verdict.branch == context.run.branch
      end

      test "the verified completion is recorded as ordered activity", context do
        pass_all(context)

        {:ok, results} = complete(context, sequence: 10)

        assert results.activity.type == VerificationCompletion.verified_activity_type()
        assert results.activity.actor_kind == "agent"
        refute results.activity.actor_account_id
        assert results.activity.payload["outcome"] == "verified"
        assert results.activity.payload["commit_sha"] == @commit
        assert results.activity.payload["branch"] == context.run.branch
        assert results.activity.payload["required_count"] == 2
        assert results.activity.payload["passed_count"] == 2

        assert {:ok, entry} =
                 VerificationCompletion.verified_completion(
                   context.authority,
                   context.project.id,
                   context.feature.id,
                   context.run.id
                 )

        assert entry.id == results.activity.id
      end

      test "the attempt's observed sequence advances with the claim", context do
        pass_all(context)

        {:ok, _results} = complete(context, sequence: 12)

        assert {:ok, %RunAttempt{last_sequence: 12}} =
                 DeliveryStore.current_attempt(
                   context.authority,
                   context.project.id,
                   context.run.id
                 )
      end
    end

    describe "refusing an unproven claim (#{authority})" do
      @describetag authority: authority

      test "a failed required check refuses and names it [AC-19]", context do
        record_check(context, 1, name: "mix test", outcome: "failed", exit_code: 1)
        record_check(context, 2, name: "mix credo")

        {:ok, results} = complete(context, sequence: 10)

        assert %Verdict{outcome: :refused, reason: :required_check_failed} = results.verdict
        assert results.verdict.failed == ["mix test"]
        assert results.verdict.passed == ["mix credo"]
        assert results.activity.type == VerificationCompletion.refused_activity_type()
        assert results.activity.payload["reason"] == "required_check_failed"
        assert results.activity.payload["failed"] == ["mix test"]
      end

      test "a contracted check with no result at all refuses as missing [AC-19]", context do
        record_check(context, 1, name: "mix test")

        {:ok, results} = complete(context, sequence: 10)

        assert %Verdict{outcome: :refused, reason: :required_check_missing} = results.verdict
        assert results.verdict.missing == ["mix credo"]
        assert results.verdict.passed == ["mix test"]
        assert results.activity.payload["missing"] == ["mix credo"]
      end

      test "a check reporting nothing to prove refuses as missing", context do
        record_check(context, 1, name: "mix test")
        record_check(context, 2, name: "mix credo", outcome: "missing", exit_code: 127)

        {:ok, results} = complete(context, sequence: 10)

        assert %Verdict{outcome: :refused, reason: :required_check_missing} = results.verdict
        assert results.verdict.missing == ["mix credo"]
      end

      test "a check the environment could not run refuses as unsupported", context do
        record_check(context, 1, name: "mix test")
        record_check(context, 2, name: "mix credo", outcome: "unsupported", exit_code: 127)

        {:ok, results} = complete(context, sequence: 10)

        assert %Verdict{outcome: :refused, reason: :required_check_unsupported} = results.verdict
        assert results.verdict.unsupported == ["mix credo"]
      end

      # The guard the whole gate exists for. An attempt that knows of no checks
      # has proved nothing, and passing evidence it never contracted for does
      # not change that.
      test "an empty contract snapshot is unknown, never 'nothing was required'", context do
        blank = another_run(context, [])

        record_check(blank, 1, name: "mix test")

        {:ok, results} = complete(blank, sequence: 10)

        assert %Verdict{outcome: :refused, reason: :required_check_contract_unknown} =
                 results.verdict

        assert results.verdict.required == []
        assert results.verdict.passed == []
        assert results.activity.type == VerificationCompletion.refused_activity_type()
      end

      test "a claim naming another branch is refused", context do
        pass_all(context)

        {:ok, results} = complete(context, sequence: 10, branch: "main")

        assert %Verdict{outcome: :refused, reason: :branch_mismatch} = results.verdict
      end

      test "a claim with no branch identity is refused", context do
        pass_all(context)

        {:ok, results} = complete(context, sequence: 10, branch: nil)

        assert %Verdict{outcome: :refused, reason: :branch_identity_missing} = results.verdict
      end

      test "a claim naming another revision is refused", context do
        pass_all(context)

        {:ok, results} = complete(context, sequence: 10, revision_id: "rev-somewhere-else")

        assert %Verdict{outcome: :refused, reason: :revision_mismatch} = results.verdict
      end

      test "a claim with no revision identity is refused", context do
        pass_all(context)

        {:ok, results} = complete(context, sequence: 10, revision_id: nil)

        assert %Verdict{outcome: :refused, reason: :revision_identity_missing} = results.verdict
      end

      test "a claim naming no commit is refused", context do
        pass_all(context)

        {:ok, results} = complete(context, sequence: 10, commit_sha: nil)

        assert %Verdict{outcome: :refused, reason: :commit_identity_missing} = results.verdict
      end
    end

    describe "binding proof to one exact commit (#{authority})" do
      @describetag authority: authority

      test "passing evidence for another commit does not satisfy the claim [AC-19]", context do
        pass_all(context)

        {:ok, results} = complete(context, sequence: 10, commit_sha: @later_commit)

        assert %Verdict{outcome: :refused, reason: :required_check_missing} = results.verdict
        assert Enum.sort(results.verdict.missing) == Enum.sort(@contract)
        assert results.verdict.passed == []
        assert results.verdict.commit_sha == @later_commit
      end

      test "results from an earlier commit do not carry forward to a later one", context do
        pass_all(context)

        # The earlier commit is genuinely complete, and stays so.
        {:ok, earlier} = complete(context, sequence: 10)
        assert earlier.verdict.outcome == :verified

        # One check reruns on the later commit; the other has not.
        record_check(context, 11, name: "mix test", commit_sha: @later_commit)

        {:ok, later} = complete(context, sequence: 12, commit_sha: @later_commit)

        assert %Verdict{outcome: :refused, reason: :required_check_missing} = later.verdict
        assert later.verdict.missing == ["mix credo"]
        assert later.verdict.passed == ["mix test"]
      end

      test "a later commit's full rerun verifies on its own evidence", context do
        pass_all(context)

        record_check(context, 11, name: "mix test", commit_sha: @later_commit)
        record_check(context, 12, name: "mix credo", commit_sha: @later_commit)

        {:ok, results} = complete(context, sequence: 13, commit_sha: @later_commit)

        assert %Verdict{outcome: :verified} = results.verdict
        assert results.verdict.commit_sha == @later_commit
      end
    end

    describe "evaluating the item that replaced another (#{authority})" do
      @describetag authority: authority

      test "a superseded passing result does not count for its replacement", context do
        record_check(context, 1, name: "mix test")
        record_check(context, 2, name: "mix credo")

        # The same check reruns on the same commit and now fails. The passing
        # item stays readable, but it is no longer what counts.
        record_check(context, 3, name: "mix test", outcome: "failed", exit_code: 1)

        {:ok, results} = complete(context, sequence: 10)

        assert %Verdict{outcome: :refused, reason: :required_check_failed} = results.verdict
        assert results.verdict.failed == ["mix test"]

        assert length(
                 EvidenceIngestion.for_run(context.authority, context.project.id, context.run.id)
               ) == 3
      end

      test "a failing result superseded by a passing rerun verifies", context do
        record_check(context, 1, name: "mix test", outcome: "failed", exit_code: 1)
        record_check(context, 2, name: "mix credo")
        record_check(context, 3, name: "mix test")

        {:ok, results} = complete(context, sequence: 10)

        assert %Verdict{outcome: :verified} = results.verdict
        assert Enum.sort(results.verdict.passed) == Enum.sort(@contract)
      end
    end

    describe "conditional screenshot evidence (#{authority})" do
      @describetag authority: authority

      test "a capture that broke refuses completion [AC-19]", context do
        pass_all(context)
        record_screenshot(context, 3, "failed", name: "board on mobile")

        {:ok, results} = complete(context, sequence: 10)

        assert %Verdict{outcome: :refused, reason: :screenshot_capture_failed} = results.verdict
        assert results.verdict.screenshots_failed == ["board on mobile"]
        assert results.activity.payload["screenshot_failed"] == ["board on mobile"]
      end

      test "nothing visual to capture does not refuse [AC-20]", context do
        pass_all(context)
        record_screenshot(context, 3, "inapplicable", name: "board on mobile")

        {:ok, results} = complete(context, sequence: 10)

        assert %Verdict{outcome: :verified} = results.verdict
        assert results.verdict.screenshots_failed == []
      end

      test "an environment that cannot capture does not refuse [AC-20]", context do
        pass_all(context)
        record_screenshot(context, 3, "unsupported", name: "board on mobile")

        {:ok, results} = complete(context, sequence: 10)

        assert %Verdict{outcome: :verified} = results.verdict
      end

      test "a captured screenshot is fine", context do
        pass_all(context)
        record_screenshot(context, 3, "captured", name: "board on mobile")

        {:ok, results} = complete(context, sequence: 10)

        assert %Verdict{outcome: :verified} = results.verdict
      end
    end

    describe "what a worker cannot earn by asserting it (#{authority})" do
      @describetag authority: authority

      test "a claim with no evidence changes no state and leaves a trace [AC-19]", context do
        {:ok, results} = complete(context, sequence: 10)

        assert %Verdict{outcome: :refused, reason: :required_check_missing} = results.verdict
        assert Enum.sort(results.verdict.missing) == Enum.sort(@contract)

        # Nothing moved. The refusal is visible instead.
        {:ok, run} =
          DeliveryStore.fetch_run(context.authority, context.project.id, context.run.id)

        assert run.state == context.run.state

        # The feature is read from the hosted row both authorities' fixtures
        # share: a device-authoritative refusal must not reach it either.
        stored = Repo.get!(Feature, context.feature.id)
        assert stored.lifecycle_column == context.feature.lifecycle_column
        assert stored.status == context.feature.status
        assert stored.state_version == context.feature.state_version

        assert :error ==
                 VerificationCompletion.verified_completion(
                   context.authority,
                   context.project.id,
                   context.feature.id,
                   context.run.id
                 )

        entries =
          DeliveryStore.list_activity(context.authority, context.project.id, context.feature.id)

        assert Enum.count(
                 entries,
                 &(&1.type == VerificationCompletion.refused_activity_type())
               ) == 1
      end

      test "a redelivered claim is applied once", context do
        pass_all(context)

        envelope = completion_event(context, sequence: 10)

        {:ok, first} =
          VerificationCompletion.ingest(context.authority, context.project.id, envelope)

        assert first.applied?

        # The same envelope again: the attempt's own sequence refuses it before
        # anything can be written a second time.
        assert {:error, :duplicate_event} =
                 VerificationCompletion.ingest(context.authority, context.project.id, envelope)

        # The same claim resent under a later sequence, as a worker that never
        # saw an acknowledgement would: its own identifier is already in the
        # history, so it replays instead of recording again.
        resent = %{envelope | "sequence" => 11}

        assert {:ok, replay} =
                 VerificationCompletion.ingest(context.authority, context.project.id, resent)

        refute replay.applied?
        assert replay.activity.id == first.activity.id

        entries =
          DeliveryStore.list_activity(context.authority, context.project.id, context.feature.id)

        assert Enum.count(
                 entries,
                 &(&1.type == VerificationCompletion.verified_activity_type())
               ) == 1
      end

      test "a superseded worker's fence claims nothing", context do
        pass_all(context)

        assert {:error, :stale_fence} =
                 VerificationCompletion.ingest(
                   context.authority,
                   context.project.id,
                   completion_event(context,
                     sequence: 10,
                     fence_token: context.attempt.fence_token + 7
                   )
                 )

        assert :error ==
                 VerificationCompletion.verified_completion(
                   context.authority,
                   context.project.id,
                   context.feature.id,
                   context.run.id
                 )
      end

      test "an event type this module does not own is refused", context do
        for type <- WorkerProtocol.event_types() -- [VerificationCompletion.event_type()] do
          envelope =
            context |> completion_event(sequence: 10) |> Map.put("event_type", type)

          assert {:error, :unsupported_event} =
                   VerificationCompletion.ingest(context.authority, context.project.id, envelope)
        end
      end

      test "progress ingestion still refuses the event this module owns", context do
        assert {:error, :unsupported_event} =
                 EventIngestion.ingest(
                   context.authority,
                   context.project.id,
                   completion_event(context, sequence: 10)
                 )
      end

      test "an envelope failing the protocol schema records nothing", context do
        base = completion_event(context, sequence: 10)

        for envelope <- [
              Map.delete(base, "occurred_at"),
              Map.put(base, "extra", "nope"),
              put_payload(base, "api_key", "sk-abcdef")
            ] do
          assert {:error, _reason} =
                   VerificationCompletion.ingest(context.authority, context.project.id, envelope)
        end

        entries =
          DeliveryStore.list_activity(context.authority, context.project.id, context.feature.id)

        assert Enum.filter(entries, &(&1.type in verification_types())) == []
      end

      test "a claim for another project's run is refused", context do
        other = DeliveryFixtures.delivery_project_fixture()

        assert {:error, :unknown_run} =
                 VerificationCompletion.ingest(
                   context.authority,
                   other.project.id,
                   completion_event(context, sequence: 10)
                 )
      end
    end
  end

  describe "the attempt's contract snapshot" do
    test "is stored, read back, and round-trips through the device value shape", %{
      authority: authority,
      project: project,
      run: run
    } do
      {:ok, attempt} = DeliveryStore.current_attempt(authority, project.id, run.id)

      assert Enum.map(attempt.required_checks, & &1["name"]) == @contract

      assert {:ok, restored} = attempt |> RunAttempt.to_value() |> RunAttempt.from_value()
      assert restored.required_checks == attempt.required_checks
    end

    test "defaults to an empty contract rather than to a guess", %{
      project: project,
      account: account
    } do
      feature = DeliveryFixtures.feature_fixture(project, account)
      run = DeliveryFixtures.run_fixture(project, feature)

      assert DeliveryFixtures.attempt_fixture(run).required_checks == []
    end

    test "a device value carrying an unnamed check is refused", %{
      authority: authority,
      project: project,
      run: run
    } do
      {:ok, attempt} = DeliveryStore.current_attempt(authority, project.id, run.id)
      value = RunAttempt.to_value(attempt)

      for broken <- [
            Map.put(value, "required_checks", [%{"command" => "mix test"}]),
            Map.put(value, "required_checks", ["mix test"]),
            Map.put(value, "required_checks", %{"name" => "mix test"})
          ] do
        assert {:error, :invalid_attempt_value} = RunAttempt.from_value(broken)
      end
    end

    test "an absent snapshot decodes to an empty contract, not to a failure", %{
      authority: authority,
      project: project,
      run: run
    } do
      {:ok, attempt} = DeliveryStore.current_attempt(authority, project.id, run.id)
      value = attempt |> RunAttempt.to_value() |> Map.delete("required_checks")

      assert {:ok, restored} = RunAttempt.from_value(value)
      assert restored.required_checks == []
    end

    test "the changeset refuses a check the gate could not look up", %{
      authority: authority,
      project: project,
      run: run
    } do
      {:ok, _attempt} = DeliveryStore.current_attempt(authority, project.id, run.id)

      changeset =
        RunAttempt.create_changeset(%RunAttempt{}, %{
          run_id: run.id,
          attempt_number: 9,
          continuation_reason: "initial",
          effective_revision_id: run.effective_revision_id,
          effective_revision_digest: run.effective_revision_digest,
          manifest_digest: DeliveryFixtures.digest("manifest"),
          required_checks: [%{"command" => "mix test"}],
          fence_token: 9
        })

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :required_checks)
    end
  end

  describe "constraints enforced by the migration" do
    test "the column defaults to an empty array", %{project: project, account: account} do
      feature = DeliveryFixtures.feature_fixture(project, account)
      run = DeliveryFixtures.run_fixture(project, feature)
      attempt = DeliveryFixtures.attempt_fixture(run)

      assert %{rows: [[stored]]} =
               Repo.query!("SELECT required_checks FROM run_attempts WHERE id = $1", [
                 Ecto.UUID.dump!(attempt.id)
               ])

      assert stored == []
    end

    test "the database refuses a snapshot that is not an array", %{
      project: project,
      account: account
    } do
      feature = DeliveryFixtures.feature_fixture(project, account)
      run = DeliveryFixtures.run_fixture(project, feature)
      attempt = DeliveryFixtures.attempt_fixture(run)

      assert_raise Postgrex.Error, ~r/run_attempts_required_checks_array/, fn ->
        Repo.query!("UPDATE run_attempts SET required_checks = '{}'::jsonb WHERE id = $1", [
          Ecto.UUID.dump!(attempt.id)
        ])
      end
    end

    test "the database accepts the two verification activity types", %{
      project: project,
      feature: feature
    } do
      for type <- verification_types() do
        assert %{num_rows: 1} =
                 Repo.query!(
                   """
                   INSERT INTO activity_entries
                     (id, project_id, feature_id, actor_kind, type, sequence, occurred_at,
                      payload, inserted_at)
                   VALUES ($1, $2, $3, 'agent', $4, $5, NOW(), '{}'::jsonb, NOW())
                   """,
                   [
                     Ecto.UUID.bingenerate(),
                     Ecto.UUID.dump!(project.id),
                     Ecto.UUID.dump!(feature.id),
                     type,
                     System.unique_integer([:positive])
                   ]
                 )
      end
    end
  end

  describe "the migration" do
    test "rolls back and forward again" do
      module = migration_module()

      assert column_exists?("run_attempts", "required_checks")

      # The lock is disabled because it would hold a second connection the Ecto
      # sandbox does not have. The migration itself still runs for real, inside
      # this test's transaction, so the rollback is proven and then undone.
      opts = [log: false, migration_lock: false]

      assert :ok = Ecto.Migrator.down(Repo, @migration_version, module, opts)
      refute column_exists?("run_attempts", "required_checks")
      refute activity_type_allowed?("verification_completed")

      assert :ok = Ecto.Migrator.up(Repo, @migration_version, module, opts)
      assert column_exists?("run_attempts", "required_checks")
      assert activity_type_allowed?("verification_completed")
    end
  end

  defp migration_module do
    module = SddOrchestrator.Repo.Migrations.AddVerificationCompletion

    if Code.ensure_loaded?(module) do
      module
    else
      path =
        Path.join([
          File.cwd!(),
          "priv/repo/migrations/20260730010000_add_verification_completion.exs"
        ])

      [{loaded, _binary} | _rest] = Code.compile_file(path)
      loaded
    end
  end

  defp column_exists?(table, column) do
    %{rows: [[count]]} =
      Repo.query!(
        """
        SELECT count(*) FROM information_schema.columns
        WHERE table_name = $1 AND column_name = $2
        """,
        [table, column]
      )

    count == 1
  end

  # The constraint is read from its own definition rather than by attempting an
  # insert, so the check survives whatever else a rolled-back schema is missing.
  defp activity_type_allowed?(type) do
    %{rows: [[definition]]} =
      Repo.query!(
        """
        SELECT pg_get_constraintdef(oid) FROM pg_constraint
        WHERE conname = 'activity_entries_type_allowed'
        """,
        []
      )

    String.contains?(definition, type)
  end

  defp verification_types do
    [
      VerificationCompletion.verified_activity_type(),
      VerificationCompletion.refused_activity_type()
    ]
  end

  # A second run of the same feature, on its own branch, bound to whatever
  # contract the test needs to prove something about.
  defp another_run(context, contract) do
    {:ok, %{run: run, attempt: attempt}} =
      DeliveryStore.commit(
        context.authority,
        context.project.id,
        run_steps(context.project, context.feature, contract)
      )

    %{context | run: run, attempt: attempt}
  end

  defp pass_all(context) do
    @contract
    |> Enum.with_index(1)
    |> Enum.each(fn {name, index} -> record_check(context, index, name: name) end)
  end

  defp record_check(context, sequence, opts) do
    {:ok, results} =
      EvidenceIngestion.ingest(
        context.authority,
        context.project.id,
        evidence_event(context, Keyword.put(opts, :sequence, sequence))
      )

    results
  end

  defp record_screenshot(context, sequence, capture_result, opts) do
    name = Keyword.fetch!(opts, :name)
    content = DeliveryFixtures.png_bytes(name)

    extra =
      if capture_result == "captured" do
        [
          digest: DeliveryFixtures.content_digest(content),
          artifact_ref:
            DeliveryFixtures.artifact_fixture(context.authority, context.project.id,
              content: content
            )
        ]
      else
        [digest: DeliveryFixtures.digest(name), artifact_ref: nil]
      end

    {:ok, results} =
      EvidenceIngestion.ingest(
        context.authority,
        context.project.id,
        evidence_event(
          context,
          [
            sequence: sequence,
            kind: "screenshot",
            name: name,
            capture_result: capture_result,
            command: "npm run screenshot",
            exit_code: nil
          ] ++ extra
        )
      )

    results
  end

  defp complete(context, opts) do
    VerificationCompletion.ingest(
      context.authority,
      context.project.id,
      completion_event(context, opts)
    )
  end

  defp run_steps(project, feature, contract) do
    unique = System.unique_integer([:positive])
    digest = DeliveryFixtures.digest("rev-#{unique}")

    [
      {:run,
       {:insert_run,
        %{
          project_id: project.id,
          feature_id: feature.id,
          starting_revision_id: "rev-#{unique}",
          starting_revision_digest: digest,
          approved_slice: "slice-07",
          branch: "sdd/feature-#{unique}"
        }}},
      {:attempt,
       {:insert_attempt,
        %{
          run_id: {:ref, :run, :id},
          attempt_number: 1,
          continuation_reason: "initial",
          effective_revision_id: "rev-#{unique}",
          effective_revision_digest: digest,
          manifest_digest: DeliveryFixtures.digest("manifest-#{unique}"),
          required_checks: DeliveryFixtures.required_check_contract(contract),
          fence_token: 1
        }}}
    ]
  end

  defp evidence_event(%{run: run, attempt: attempt}, opts) do
    name = Keyword.get(opts, :name, "mix test")

    payload = %{
      "kind" => Keyword.get(opts, :kind, "required_check"),
      "name" => name,
      "outcome" => Keyword.get(opts, :outcome, "passed"),
      "command" => Keyword.get(opts, :command, name),
      "exit_code" => Keyword.get(opts, :exit_code, 0),
      "duration_ms" => Keyword.get(opts, :duration_ms, 4_200),
      "commit_sha" => Keyword.get(opts, :commit_sha, @commit),
      "digest" => Keyword.get(opts, :digest, DeliveryFixtures.digest(name)),
      "redacted" => false,
      "artifact_ref" => Keyword.get(opts, :artifact_ref),
      "capture_result" => Keyword.get(opts, :capture_result)
    }

    envelope(run, attempt, opts, "evidence", "check", payload)
  end

  defp completion_event(%{run: run, attempt: attempt}, opts) do
    payload = %{
      "branch" => Keyword.get(opts, :branch, run.branch),
      "revision_id" => Keyword.get(opts, :revision_id, attempt.effective_revision_id),
      "commit_sha" => Keyword.get(opts, :commit_sha, @commit)
    }

    envelope(run, attempt, opts, "verification_completed", "worker", payload)
  end

  defp envelope(run, attempt, opts, event_type, source, payload) do
    unique = System.unique_integer([:positive])

    %{
      "type" => "event",
      "protocol_version" => WorkerProtocol.version(),
      "event_id" => Keyword.get(opts, :event_id, "evt-#{unique}"),
      "run_id" => run.id,
      "command_id" => Keyword.get(opts, :command_id, "cmd-#{unique}"),
      "attempt_number" => attempt.attempt_number,
      "fence_token" => Keyword.get(opts, :fence_token, attempt.fence_token),
      "sequence" => Keyword.fetch!(opts, :sequence),
      "event_type" => event_type,
      "source" => Keyword.get(opts, :source, source),
      "occurred_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "payload" => payload
    }
  end

  defp put_payload(envelope, key, value),
    do: Map.put(envelope, "payload", Map.put(envelope["payload"], key, value))
end
