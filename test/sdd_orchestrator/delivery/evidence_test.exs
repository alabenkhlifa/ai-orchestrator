defmodule SddOrchestrator.Delivery.EvidenceTest do
  @moduledoc """
  Proof for normalized required-check evidence (Task 4).

  One promise is being pinned above all others: proof comes from a command
  result, never from what the agent said about its own work. An `agent`-sourced
  event is refused by the ingestion path, by the changeset, and by a database
  check constraint, so no code path, console session, or future migration can
  turn narrative into a satisfied required check.

  The second promise is that a recorded item is never rewritten. A rerun records
  a new item and links the old one to it, and a database trigger rejects every
  other update, so a reader can still see what was superseded and by what.

  Every behavioural test runs against both storage authorities, because `specs/05`
  forbids keeping a device-authoritative project's evidence in the hosted
  database and two implementations are only safe once they answer the same way.
  """
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Accounts.DeviceWorkspace

  alias SddOrchestrator.Delivery.{
    ActivityEntry,
    DeliveryStore,
    EventIngestion,
    Evidence,
    EvidenceIngestion,
    RunAttempt,
    WorkerProtocol
  }

  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.DeviceStore.Local
  alias SddOrchestrator.Repo

  @commit "a1b2c3d4e5f6a7b8c9d0"

  setup context do
    hosted = DeliveryFixtures.delivery_project_fixture()
    feature = DeliveryFixtures.feature_fixture(hosted.project, hosted.account)

    path =
      Path.join(System.tmp_dir!(), "evidence-#{System.unique_integer([:positive])}.dets")

    start_supervised!({Local, path: path})
    on_exit(fn -> File.rm_rf(path) end)

    {:ok, device_workspace} = Devices.establish_workspace()

    authority =
      case context[:authority] do
        :device -> %DeviceWorkspace{id: device_workspace.id}
        _hosted -> hosted.workspace
      end

    {:ok, %{run: run, attempt: attempt}} =
      DeliveryStore.commit(authority, hosted.project.id, run_steps(hosted.project, feature))

    %{
      authority: authority,
      project: hosted.project,
      feature: feature,
      run: run,
      attempt: attempt
    }
  end

  # Every behaviour below runs twice: once against PostgreSQL and once against
  # the worker-owned device store.
  for authority <- [:hosted, :device] do
    describe "recording one command result (#{authority})" do
      @describetag authority: authority

      test "stores the outcome with the provenance that makes it checkable [AC-40]", %{
        authority: authority,
        project: project,
        run: run
      } do
        assert {:ok, results} =
                 EvidenceIngestion.ingest(
                   authority,
                   project.id,
                   evidence_event(run, results_attempt(authority, project, run),
                     sequence: 1,
                     name: "mix test",
                     command: "mix test --warnings-as-errors",
                     outcome: "failed",
                     exit_code: 2,
                     duration_ms: 41_320
                   )
                 )

        assert results.evidence.kind == "required_check"
        assert results.evidence.name == "mix test"
        assert results.evidence.outcome == "failed"
        assert results.evidence.command == "mix test --warnings-as-errors"
        assert results.evidence.exit_code == 2
        assert results.evidence.duration_ms == 41_320
        assert results.evidence.commit_sha == @commit
        assert results.evidence.source == "check"
        assert results.evidence.recorded_at
        assert results.evidence.digest =~ ~r/\A[0-9a-f]{64}\z/
      end

      test "binds the item to its project, feature, run, attempt, and redaction state", %{
        authority: authority,
        project: project,
        feature: feature,
        run: run,
        attempt: attempt
      } do
        {:ok, results} =
          EvidenceIngestion.ingest(
            authority,
            project.id,
            evidence_event(run, attempt, sequence: 1, redacted: true)
          )

        assert results.evidence.project_id == project.id
        assert results.evidence.feature_id == feature.id
        assert results.evidence.run_id == run.id
        assert results.evidence.attempt_id == attempt.id
        assert results.evidence.redacted
        refute results.evidence.superseded_by_id
      end

      test "the branch comes from the run, never from the worker", %{
        authority: authority,
        project: project,
        run: run,
        attempt: attempt
      } do
        envelope = evidence_event(run, attempt, sequence: 1)
        envelope = put_payload(envelope, "branch", "main")

        {:ok, results} = EvidenceIngestion.ingest(authority, project.id, envelope)

        assert results.evidence.branch == run.branch
      end

      # A screenshot is not a command result, so the command provenance a
      # required check must carry does not apply to it. What it must carry
      # instead — a reported capture result and bytes the project's own store
      # actually holds — belongs to `ScreenshotEvidenceTest`.
      test "accepts a screenshot without command provenance", %{
        authority: authority,
        project: project,
        run: run,
        attempt: attempt
      } do
        content = DeliveryFixtures.png_bytes("board-mobile")
        ref = DeliveryFixtures.artifact_fixture(authority, project.id, content: content)

        {:ok, results} =
          EvidenceIngestion.ingest(
            authority,
            project.id,
            evidence_event(run, attempt,
              sequence: 1,
              kind: "screenshot",
              name: "board on mobile",
              command: nil,
              exit_code: nil,
              capture_result: "captured",
              digest: DeliveryFixtures.content_digest(content),
              artifact_ref: ref
            )
          )

        assert results.evidence.kind == "screenshot"
        assert results.evidence.artifact_ref == ref
        refute results.evidence.exit_code
      end

      test "records one entry in the feature's history", %{
        authority: authority,
        project: project,
        feature: feature,
        run: run,
        attempt: attempt
      } do
        {:ok, results} =
          EvidenceIngestion.ingest(
            authority,
            project.id,
            evidence_event(run, attempt, sequence: 1, name: "mix credo")
          )

        assert %ActivityEntry{} = results.activity
        assert results.activity.type == "evidence_recorded"
        assert results.activity.actor_kind == "agent"
        refute results.activity.actor_account_id
        assert results.activity.payload["evidence_id"] == results.evidence.id
        assert results.activity.payload["name"] == "mix credo"
        assert results.activity.payload["outcome"] == "passed"
        assert results.activity.payload["source"] == "check"
        assert results.activity.payload["branch"] == run.branch
        assert results.activity.payload["commit_sha"] == @commit

        entries = DeliveryStore.list_activity(authority, project.id, feature.id)
        assert Enum.count(entries, &(&1.type == "evidence_recorded")) == 1
      end

      test "advances the attempt's observed sequence", %{
        authority: authority,
        project: project,
        run: run,
        attempt: attempt
      } do
        {:ok, _results} =
          EvidenceIngestion.ingest(
            authority,
            project.id,
            evidence_event(run, attempt, sequence: 6)
          )

        assert {:ok, %RunAttempt{last_sequence: 6}} =
                 DeliveryStore.current_attempt(authority, project.id, run.id)
      end

      test "reads the run's, the attempt's, and the commit's proof", %{
        authority: authority,
        project: project,
        run: run,
        attempt: attempt
      } do
        {:ok, first} =
          EvidenceIngestion.ingest(
            authority,
            project.id,
            evidence_event(run, attempt, sequence: 1, name: "mix test")
          )

        {:ok, second} =
          EvidenceIngestion.ingest(
            authority,
            project.id,
            evidence_event(run, attempt,
              sequence: 2,
              name: "mix credo",
              commit_sha: "0f0f0f0f0f0f0f0f0f0f"
            )
          )

        run_ids = authority |> EvidenceIngestion.for_run(project.id, run.id) |> ids()
        assert Enum.sort(run_ids) == Enum.sort([first.evidence.id, second.evidence.id])

        attempt_ids =
          authority |> EvidenceIngestion.for_attempt(project.id, attempt.id) |> ids()

        assert Enum.sort(attempt_ids) == Enum.sort([first.evidence.id, second.evidence.id])

        assert authority
               |> EvidenceIngestion.current_for_commit(project.id, run.id, @commit)
               |> ids() == [first.evidence.id]
      end
    end

    describe "refusing what must not become proof (#{authority})" do
      @describetag authority: authority

      test "an agent's account of its own work is refused outright", %{
        authority: authority,
        project: project,
        run: run,
        attempt: attempt
      } do
        # Everything else about this event is correct: the fence is current, the
        # sequence advances, and the payload is complete. Only the source
        # disqualifies it, which is exactly the assertion being made.
        envelope = evidence_event(run, attempt, sequence: 1, source: "agent")

        assert {:error, :agent_evidence_refused} =
                 EvidenceIngestion.ingest(authority, project.id, envelope)

        assert EvidenceIngestion.for_run(authority, project.id, run.id) == []
      end

      test "an agent-sourced event is refused before its run is even resolved", %{
        authority: authority,
        project: project,
        run: run,
        attempt: attempt
      } do
        envelope =
          run
          |> evidence_event(attempt, sequence: 1, source: "agent")
          |> Map.put("run_id", Ecto.UUID.generate())

        assert {:error, :agent_evidence_refused} =
                 EvidenceIngestion.ingest(authority, project.id, envelope)
      end

      test "the changeset itself refuses an agent source", %{run: run, attempt: attempt} do
        changeset =
          Evidence.record_changeset(%Evidence{}, record_attrs(run, attempt, source: "agent"))

        refute changeset.valid?
        assert Keyword.has_key?(changeset.errors, :source)
        refute "agent" in Evidence.sources()
      end

      test "a superseded worker's fence records nothing", %{
        authority: authority,
        project: project,
        run: run,
        attempt: attempt
      } do
        envelope = evidence_event(run, attempt, sequence: 1, fence_token: attempt.fence_token + 7)

        assert {:error, :stale_fence} = EvidenceIngestion.ingest(authority, project.id, envelope)
        assert EvidenceIngestion.for_run(authority, project.id, run.id) == []
      end

      test "a replayed event is a duplicate, not a second item", %{
        authority: authority,
        project: project,
        run: run,
        attempt: attempt
      } do
        envelope = evidence_event(run, attempt, sequence: 3)

        {:ok, _first} = EvidenceIngestion.ingest(authority, project.id, envelope)

        assert {:error, :duplicate_event} =
                 EvidenceIngestion.ingest(authority, project.id, envelope)

        assert length(EvidenceIngestion.for_run(authority, project.id, run.id)) == 1
      end

      test "an out-of-order event is refused", %{
        authority: authority,
        project: project,
        run: run,
        attempt: attempt
      } do
        {:ok, _first} =
          EvidenceIngestion.ingest(
            authority,
            project.id,
            evidence_event(run, attempt, sequence: 5)
          )

        assert {:error, :stale_sequence} =
                 EvidenceIngestion.ingest(
                   authority,
                   project.id,
                   evidence_event(run, attempt, sequence: 4)
                 )

        assert length(EvidenceIngestion.for_run(authority, project.id, run.id)) == 1
      end

      test "an oversized event never reaches storage", %{
        authority: authority,
        project: project,
        run: run,
        attempt: attempt
      } do
        oversized_payload =
          run
          |> evidence_event(attempt, sequence: 1)
          |> put_payload("command", String.duplicate("x", 70_000))

        assert {:error, :payload_too_large} =
                 EvidenceIngestion.ingest(authority, project.id, oversized_payload)

        oversized_name =
          evidence_event(run, attempt, sequence: 1, name: String.duplicate("n", 201))

        assert {:error, :invalid_evidence} =
                 EvidenceIngestion.ingest(authority, project.id, oversized_name)

        assert EvidenceIngestion.for_run(authority, project.id, run.id) == []
      end

      test "an envelope failing the protocol schema never reaches storage", %{
        authority: authority,
        project: project,
        run: run,
        attempt: attempt
      } do
        base = evidence_event(run, attempt, sequence: 1)
        malformed = Map.delete(base, "occurred_at")
        unknown_field = Map.put(base, "extra", "nope")
        credential = put_payload(base, "api_key", "sk-abcdef")

        for envelope <- [malformed, unknown_field, credential] do
          assert {:error, _reason} = EvidenceIngestion.ingest(authority, project.id, envelope)
        end

        assert EvidenceIngestion.for_run(authority, project.id, run.id) == []
      end

      test "an event type this module does not own is refused", %{
        authority: authority,
        project: project,
        run: run,
        attempt: attempt
      } do
        for type <- WorkerProtocol.event_types() -- [EvidenceIngestion.event_type()] do
          envelope =
            run |> evidence_event(attempt, sequence: 1) |> Map.put("event_type", type)

          assert {:error, :unsupported_event} =
                   EvidenceIngestion.ingest(authority, project.id, envelope)
        end
      end

      test "progress ingestion still refuses the evidence event this module owns", %{
        authority: authority,
        project: project,
        run: run,
        attempt: attempt
      } do
        assert {:error, :unsupported_event} =
                 EventIngestion.ingest(
                   authority,
                   project.id,
                   evidence_event(run, attempt, sequence: 1)
                 )

        assert EvidenceIngestion.for_run(authority, project.id, run.id) == []
      end

      test "incomplete provenance is refused rather than stored", %{
        authority: authority,
        project: project,
        run: run,
        attempt: attempt
      } do
        incomplete = [
          evidence_event(run, attempt, sequence: 1, exit_code: nil),
          evidence_event(run, attempt, sequence: 1, command: nil),
          evidence_event(run, attempt, sequence: 1, digest: nil),
          evidence_event(run, attempt, sequence: 1, digest: "not-a-digest"),
          evidence_event(run, attempt, sequence: 1, commit_sha: nil),
          evidence_event(run, attempt, sequence: 1, duration_ms: -1),
          evidence_event(run, attempt, sequence: 1, kind: "guesswork"),
          evidence_event(run, attempt, sequence: 1, outcome: "probably")
        ]

        for envelope <- incomplete do
          assert {:error, :invalid_evidence} =
                   EvidenceIngestion.ingest(authority, project.id, envelope)
        end

        assert EvidenceIngestion.for_run(authority, project.id, run.id) == []
      end

      test "an event for another project's run is refused", %{
        authority: authority,
        run: run,
        attempt: attempt
      } do
        other = DeliveryFixtures.delivery_project_fixture()

        assert {:error, :unknown_run} =
                 EvidenceIngestion.ingest(
                   authority,
                   other.project.id,
                   evidence_event(run, attempt, sequence: 1)
                 )
      end

      test "recorded proof is not readable under another project", %{
        authority: authority,
        project: project,
        run: run,
        attempt: attempt
      } do
        {:ok, _results} =
          EvidenceIngestion.ingest(
            authority,
            project.id,
            evidence_event(run, attempt, sequence: 1)
          )

        other = DeliveryFixtures.delivery_project_fixture()

        assert EvidenceIngestion.for_run(authority, other.project.id, run.id) == []
        assert EvidenceIngestion.for_attempt(authority, other.project.id, attempt.id) == []

        assert EvidenceIngestion.current_for_commit(
                 authority,
                 other.project.id,
                 run.id,
                 @commit
               ) == []
      end
    end

    describe "superseding an earlier result (#{authority})" do
      @describetag authority: authority

      test "a rerun of the same check on the same commit replaces what still counts", %{
        authority: authority,
        project: project,
        run: run,
        attempt: attempt
      } do
        {:ok, first} =
          EvidenceIngestion.ingest(
            authority,
            project.id,
            evidence_event(run, attempt, sequence: 1, outcome: "failed", exit_code: 1)
          )

        {:ok, second} =
          EvidenceIngestion.ingest(
            authority,
            project.id,
            evidence_event(run, attempt, sequence: 2, outcome: "passed", exit_code: 0)
          )

        assert second.superseded.id == first.evidence.id
        assert second.superseded.superseded_by_id == second.evidence.id

        # The earlier result is not deleted or rewritten: it stays readable as
        # the thing that was superseded.
        assert authority |> EvidenceIngestion.for_run(project.id, run.id) |> length() == 2

        assert authority
               |> EvidenceIngestion.current_for_commit(project.id, run.id, @commit)
               |> ids() == [second.evidence.id]

        assert second.activity.payload["supersedes_evidence_id"] == first.evidence.id
      end

      test "the superseded item keeps its own outcome", %{
        authority: authority,
        project: project,
        run: run,
        attempt: attempt
      } do
        {:ok, first} =
          EvidenceIngestion.ingest(
            authority,
            project.id,
            evidence_event(run, attempt, sequence: 1, outcome: "failed", exit_code: 1)
          )

        {:ok, _second} =
          EvidenceIngestion.ingest(
            authority,
            project.id,
            evidence_event(run, attempt, sequence: 2, outcome: "passed", exit_code: 0)
          )

        stored =
          authority
          |> EvidenceIngestion.for_run(project.id, run.id)
          |> Enum.find(&(&1.id == first.evidence.id))

        assert stored.outcome == "failed"
        assert stored.exit_code == 1
        assert stored.digest == first.evidence.digest
      end

      test "a different check on the same commit supersedes nothing", %{
        authority: authority,
        project: project,
        run: run,
        attempt: attempt
      } do
        {:ok, first} =
          EvidenceIngestion.ingest(
            authority,
            project.id,
            evidence_event(run, attempt, sequence: 1, name: "mix test")
          )

        {:ok, second} =
          EvidenceIngestion.ingest(
            authority,
            project.id,
            evidence_event(run, attempt, sequence: 2, name: "mix credo", command: "mix credo")
          )

        refute Map.has_key?(second, :superseded)

        current =
          authority |> EvidenceIngestion.current_for_commit(project.id, run.id, @commit) |> ids()

        assert Enum.sort(current) == Enum.sort([first.evidence.id, second.evidence.id])
      end

      test "the same check on a later commit supersedes nothing", %{
        authority: authority,
        project: project,
        run: run,
        attempt: attempt
      } do
        {:ok, first} =
          EvidenceIngestion.ingest(
            authority,
            project.id,
            evidence_event(run, attempt, sequence: 1)
          )

        later = "b2b2b2b2b2b2b2b2b2b2"

        {:ok, second} =
          EvidenceIngestion.ingest(
            authority,
            project.id,
            evidence_event(run, attempt, sequence: 2, commit_sha: later)
          )

        refute Map.has_key?(second, :superseded)

        assert authority
               |> EvidenceIngestion.current_for_commit(project.id, run.id, @commit)
               |> ids() == [first.evidence.id]

        assert authority
               |> EvidenceIngestion.current_for_commit(project.id, run.id, later)
               |> ids() == [second.evidence.id]
      end
    end
  end

  describe "immutability enforced by the database" do
    test "no changeset can rewrite a recorded field", %{
      authority: authority,
      project: project,
      run: run,
      attempt: attempt
    } do
      {:ok, %{evidence: evidence}} =
        EvidenceIngestion.ingest(
          authority,
          project.id,
          evidence_event(run, attempt, sequence: 1)
        )

      replacement = Ecto.UUID.generate()
      changeset = Evidence.supersede_changeset(evidence, replacement, evidence.state_version)

      # The supersession link is the only thing this changeset is capable of
      # moving; the optimistic-lock version is bumped by the repo itself.
      assert Map.keys(changeset.changes) == [:superseded_by_id]
      assert Map.keys(changeset.filters) == [:state_version]
    end

    test "a rewrite offered against a superseded version is refused", %{
      authority: authority,
      project: project,
      run: run,
      attempt: attempt
    } do
      {:ok, %{evidence: evidence}} =
        EvidenceIngestion.ingest(
          authority,
          project.id,
          evidence_event(run, attempt, sequence: 1)
        )

      changeset =
        Evidence.supersede_changeset(
          evidence,
          Ecto.UUID.generate(),
          evidence.state_version + 1
        )

      refute changeset.valid?
    end

    test "an item cannot supersede itself", %{
      authority: authority,
      project: project,
      run: run,
      attempt: attempt
    } do
      {:ok, %{evidence: evidence}} =
        EvidenceIngestion.ingest(
          authority,
          project.id,
          evidence_event(run, attempt, sequence: 1)
        )

      changeset = Evidence.supersede_changeset(evidence, evidence.id, evidence.state_version)

      refute changeset.valid?
    end

    test "an already superseded item cannot be relinked", %{
      authority: authority,
      project: project,
      run: run,
      attempt: attempt
    } do
      {:ok, _first} =
        EvidenceIngestion.ingest(
          authority,
          project.id,
          evidence_event(run, attempt, sequence: 1, outcome: "failed", exit_code: 1)
        )

      {:ok, second} =
        EvidenceIngestion.ingest(
          authority,
          project.id,
          evidence_event(run, attempt, sequence: 2)
        )

      superseded = Repo.get!(Evidence, second.superseded.id)

      changeset =
        Evidence.supersede_changeset(
          superseded,
          Ecto.UUID.generate(),
          superseded.state_version
        )

      refute changeset.valid?
    end

    test "the database rejects an update to any recorded column", %{
      authority: authority,
      project: project,
      run: run,
      attempt: attempt
    } do
      {:ok, %{evidence: evidence}} =
        EvidenceIngestion.ingest(
          authority,
          project.id,
          evidence_event(run, attempt, sequence: 1, outcome: "failed", exit_code: 1)
        )

      assert_raise Postgrex.Error, ~r/immutable/, fn ->
        Repo.update_all(
          from(e in Evidence, where: e.id == ^evidence.id),
          set: [outcome: "passed", exit_code: 0]
        )
      end
    end

    test "the database rejects a second supersession link", %{
      authority: authority,
      project: project,
      run: run,
      attempt: attempt
    } do
      {:ok, _first} =
        EvidenceIngestion.ingest(
          authority,
          project.id,
          evidence_event(run, attempt, sequence: 1, outcome: "failed", exit_code: 1)
        )

      {:ok, second} =
        EvidenceIngestion.ingest(
          authority,
          project.id,
          evidence_event(run, attempt, sequence: 2)
        )

      assert_raise Postgrex.Error, ~r/recorded once/, fn ->
        Repo.update_all(
          from(e in Evidence, where: e.id == ^second.superseded.id),
          set: [superseded_by_id: nil]
        )
      end
    end
  end

  describe "constraints enforced by the migration" do
    test "the database refuses agent-sourced evidence", %{run: run, attempt: attempt} do
      assert_raise Ecto.ConstraintError, ~r/evidence_source_allowed/, fn ->
        raw_insert!(run, attempt, source: "agent")
      end
    end

    test "the database refuses an unknown kind", %{run: run, attempt: attempt} do
      assert_raise Ecto.ConstraintError, ~r/evidence_kind_allowed/, fn ->
        raw_insert!(run, attempt, kind: "vibes")
      end
    end

    test "the database refuses an unknown outcome", %{run: run, attempt: attempt} do
      assert_raise Ecto.ConstraintError, ~r/evidence_outcome_allowed/, fn ->
        raw_insert!(run, attempt, outcome: "probably")
      end
    end

    test "the database refuses a required check with no exit code", %{
      run: run,
      attempt: attempt
    } do
      assert_raise Ecto.ConstraintError, ~r/evidence_required_check_provenance/, fn ->
        raw_insert!(run, attempt, exit_code: nil)
      end
    end

    test "the database refuses a negative duration", %{run: run, attempt: attempt} do
      assert_raise Ecto.ConstraintError, ~r/evidence_duration_non_negative/, fn ->
        raw_insert!(run, attempt, duration_ms: -1)
      end
    end

    test "the database refuses a digest that is not a content digest", %{
      run: run,
      attempt: attempt
    } do
      assert_raise Ecto.ConstraintError, ~r/evidence_digest_format/, fn ->
        raw_insert!(run, attempt, digest: "trust me")
      end
    end
  end

  describe "the device value shape" do
    test "round-trips one recorded item", %{
      authority: authority,
      project: project,
      run: run,
      attempt: attempt
    } do
      {:ok, %{evidence: evidence}} =
        EvidenceIngestion.ingest(
          authority,
          project.id,
          evidence_event(run, attempt, sequence: 1, redacted: true)
        )

      assert {:ok, restored} = evidence |> Evidence.to_value() |> Evidence.from_value()

      assert restored.id == evidence.id
      assert restored.kind == evidence.kind
      assert restored.outcome == evidence.outcome
      assert restored.command == evidence.command
      assert restored.exit_code == evidence.exit_code
      assert restored.source == evidence.source
      assert restored.digest == evidence.digest
      assert restored.redacted == evidence.redacted
      assert restored.state_version == evidence.state_version
    end

    test "refuses a value the device store could not have written" do
      value = Evidence.to_value(%Evidence{} |> Map.merge(sample_struct_fields()))

      for broken <- [
            Map.put(value, "source", "agent"),
            Map.put(value, "kind", "vibes"),
            Map.put(value, "outcome", "probably"),
            Map.put(value, "duration_ms", -1),
            Map.put(value, "redacted", "yes"),
            Map.delete(value, "digest")
          ] do
        assert {:error, :invalid_evidence_value} = Evidence.from_value(broken)
      end

      assert {:error, :invalid_evidence_value} = Evidence.from_value("not a map")
    end
  end

  defp ids(evidence), do: Enum.map(evidence, & &1.id)

  # The attempt the store holds now, which is the one whose sequence and fence
  # an event has to match.
  defp results_attempt(authority, project, run) do
    {:ok, attempt} = DeliveryStore.current_attempt(authority, project.id, run.id)
    attempt
  end

  defp run_steps(project, feature) do
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
          fence_token: 1
        }}}
    ]
  end

  defp evidence_event(run, attempt, opts) do
    payload = %{
      "kind" => Keyword.get(opts, :kind, "required_check"),
      "name" => Keyword.get(opts, :name, "mix test"),
      "outcome" => Keyword.get(opts, :outcome, "passed"),
      "command" => Keyword.get(opts, :command, "mix test"),
      "exit_code" => Keyword.get(opts, :exit_code, 0),
      "duration_ms" => Keyword.get(opts, :duration_ms, 4_200),
      "commit_sha" => Keyword.get(opts, :commit_sha, @commit),
      "digest" => Keyword.get(opts, :digest, DeliveryFixtures.digest("mix test")),
      "redacted" => Keyword.get(opts, :redacted, false),
      "artifact_ref" => Keyword.get(opts, :artifact_ref),
      "capture_result" => Keyword.get(opts, :capture_result)
    }

    %{
      "type" => "event",
      "protocol_version" => WorkerProtocol.version(),
      "event_id" => "evt-#{System.unique_integer([:positive])}",
      "run_id" => run.id,
      "command_id" => Keyword.get(opts, :command_id, "cmd-#{System.unique_integer([:positive])}"),
      "attempt_number" => attempt.attempt_number,
      "fence_token" => Keyword.get(opts, :fence_token, attempt.fence_token),
      "sequence" => Keyword.fetch!(opts, :sequence),
      "event_type" => "evidence",
      "source" => Keyword.get(opts, :source, "check"),
      "occurred_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "payload" => payload
    }
  end

  defp put_payload(envelope, key, value),
    do: Map.put(envelope, "payload", Map.put(envelope["payload"], key, value))

  defp record_attrs(run, attempt, overrides) do
    %{
      project_id: run.project_id,
      feature_id: run.feature_id,
      run_id: run.id,
      attempt_id: attempt.id,
      command_id: "cmd-#{System.unique_integer([:positive])}",
      kind: "required_check",
      name: "mix test",
      outcome: "passed",
      command: "mix test",
      exit_code: 0,
      duration_ms: 4_200,
      branch: run.branch,
      commit_sha: @commit,
      source: "check",
      recorded_at: DateTime.utc_now(),
      digest: DeliveryFixtures.digest("mix test"),
      redacted: false
    }
    |> Map.merge(Map.new(overrides))
  end

  # Inserted without the changeset so the constraint under test is the one the
  # database itself holds, not the one the schema restates.
  defp raw_insert!(run, attempt, overrides) do
    %Evidence{}
    |> Ecto.Changeset.change(record_attrs(run, attempt, overrides))
    |> Repo.insert!()
  end

  defp sample_struct_fields do
    %{
      id: Ecto.UUID.generate(),
      project_id: Ecto.UUID.generate(),
      feature_id: Ecto.UUID.generate(),
      run_id: Ecto.UUID.generate(),
      attempt_id: Ecto.UUID.generate(),
      command_id: "cmd-1",
      kind: "required_check",
      name: "mix test",
      outcome: "passed",
      command: "mix test",
      exit_code: 0,
      duration_ms: 4_200,
      branch: "sdd/feature-1",
      commit_sha: @commit,
      source: "check",
      recorded_at: DateTime.utc_now(),
      digest: DeliveryFixtures.digest("mix test"),
      redacted: false,
      state_version: 1
    }
  end
end
