defmodule SddOrchestrator.Delivery.ScreenshotEvidenceTest do
  @moduledoc """
  Proof for conditional screenshot evidence (Task 44, AC-20).

  The promise being pinned is narrow and absolute: when a capture is possible
  and meaningful the picture is attached to the feature's evidence, and when it
  is not, the absence is recorded as an explicit typed result with a reason.
  Silence is never an answer, and neither is a screenshot nobody took.

  Every refusal below exists because the alternative is invented evidence. A
  `captured` result whose bytes the project's own store does not hold, whose
  declared digest addresses something else, whose redaction claim contradicts
  the stored artifact, or which comes from a worker that never negotiated the
  capture capability is refused outright rather than quietly downgraded to an
  absence — a weakened claim would read to a later reviewer exactly like an
  honest "nothing to capture".

  Every behavioural test runs against both storage authorities, because
  `specs/05` forbids keeping a device-authoritative project's evidence or
  artifacts in the hosted database and two implementations are only safe once
  they answer the same way.
  """
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Accounts.DeviceWorkspace

  alias SddOrchestrator.Delivery.{
    ArtifactStore,
    DeliveryStore,
    Evidence,
    EvidenceIngestion,
    ScreenshotEvidence,
    WorkerProtocol
  }

  alias SddOrchestrator.Delivery.CommandTransport.Channel
  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.DeviceStore.Local

  @commit "a1b2c3d4e5f6a7b8c9d0"

  setup context do
    hosted = DeliveryFixtures.delivery_project_fixture()
    feature = DeliveryFixtures.feature_fixture(hosted.project, hosted.account)

    path =
      Path.join(System.tmp_dir!(), "screenshot-#{System.unique_integer([:positive])}.dets")

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
    describe "attaching a capture that actually happened (#{authority})" do
      @describetag authority: authority

      test "visual work with a supported capture attaches the stored artifact [AC-20]", %{
        authority: authority,
        project: project,
        run: run,
        attempt: attempt
      } do
        capture = store_capture(authority, project)

        assert {:ok, results} =
                 EvidenceIngestion.ingest(
                   authority,
                   project.id,
                   screenshot_event(run, attempt,
                     sequence: 1,
                     capture_result: "captured",
                     digest: capture.digest,
                     artifact_ref: capture.ref
                   )
                 )

        assert results.evidence.kind == "screenshot"
        assert results.evidence.outcome == "passed"
        assert results.evidence.source == "worker"
        assert results.evidence.artifact_ref == capture.ref
        assert results.evidence.digest == capture.digest

        # The reference is not decorative: the bytes are still reachable through
        # the project's own storage authority afterwards.
        assert {:ok, stored} =
                 ArtifactStore.fetch(authority, project.id, results.evidence.artifact_ref)

        assert stored.content == capture.content
        assert stored.content_type == "image/png"
      end

      test "the capture is bound to the exact attempt and commit", %{
        authority: authority,
        project: project,
        feature: feature,
        run: run,
        attempt: attempt
      } do
        capture = store_capture(authority, project)

        {:ok, results} =
          EvidenceIngestion.ingest(
            authority,
            project.id,
            screenshot_event(run, attempt,
              sequence: 1,
              capture_result: "captured",
              digest: capture.digest,
              artifact_ref: capture.ref
            )
          )

        assert results.evidence.attempt_id == attempt.id
        assert results.evidence.run_id == run.id
        assert results.evidence.feature_id == feature.id
        assert results.evidence.commit_sha == @commit

        assert authority
               |> EvidenceIngestion.current_for_commit(project.id, run.id, @commit)
               |> Enum.map(& &1.id) == [results.evidence.id]

        # A different commit has nothing to show, which is what makes the
        # binding worth having.
        assert EvidenceIngestion.current_for_commit(
                 authority,
                 project.id,
                 run.id,
                 "0f0f0f0f0f0f0f0f0f0f"
               ) == []
      end

      test "the branch comes from the run, and a claimed one cannot change it", %{
        authority: authority,
        project: project,
        run: run,
        attempt: attempt
      } do
        capture = store_capture(authority, project)

        envelope =
          run
          |> screenshot_event(attempt,
            sequence: 1,
            capture_result: "captured",
            digest: capture.digest,
            artifact_ref: capture.ref
          )
          |> put_payload("branch", "main")

        {:ok, results} = EvidenceIngestion.ingest(authority, project.id, envelope)

        assert results.evidence.branch == run.branch
        refute results.evidence.branch == "main"
      end

      test "a redacted capture is recorded as redacted", %{
        authority: authority,
        project: project,
        run: run,
        attempt: attempt
      } do
        capture = store_capture(authority, project, redacted: true)

        {:ok, results} =
          EvidenceIngestion.ingest(
            authority,
            project.id,
            screenshot_event(run, attempt,
              sequence: 1,
              capture_result: "captured",
              digest: capture.digest,
              artifact_ref: capture.ref,
              redacted: true
            )
          )

        assert results.evidence.redacted
        assert {:ok, stored} = ArtifactStore.stat(authority, project.id, capture.ref)
        assert stored.redacted
      end

      test "a worker that negotiated the capture capability is believed", %{
        authority: authority,
        project: project,
        run: run,
        attempt: attempt
      } do
        capture = store_capture(authority, project)
        attach_worker(project.id, WorkerProtocol.capabilities())

        assert {:ok, results} =
                 EvidenceIngestion.ingest(
                   authority,
                   project.id,
                   screenshot_event(run, attempt,
                     sequence: 1,
                     capture_result: "captured",
                     digest: capture.digest,
                     artifact_ref: capture.ref
                   )
                 )

        assert results.evidence.outcome == "passed"
      end

      test "with no worker attached the stored artifact is the whole proof", %{
        authority: authority,
        project: project,
        run: run,
        attempt: attempt
      } do
        capture = store_capture(authority, project)

        # Nothing is listening, so there is no contract to read. The bytes had to
        # survive an authenticated upload to be here at all, and that proof does
        # not depend on who is connected now.
        assert Channel.attached(project.id) == []

        assert {:ok, results} =
                 EvidenceIngestion.ingest(
                   authority,
                   project.id,
                   screenshot_event(run, attempt,
                     sequence: 1,
                     capture_result: "captured",
                     digest: capture.digest,
                     artifact_ref: capture.ref
                   )
                 )

        assert results.evidence.outcome == "passed"
      end
    end

    describe "reporting that there is nothing to show (#{authority})" do
      @describetag authority: authority

      test "non-visual work records an explicit absence, not silence [AC-20]", %{
        authority: authority,
        project: project,
        run: run,
        attempt: attempt
      } do
        assert {:ok, results} =
                 EvidenceIngestion.ingest(
                   authority,
                   project.id,
                   screenshot_event(run, attempt,
                     sequence: 1,
                     capture_result: "inapplicable",
                     name: "no visual result"
                   )
                 )

        assert results.evidence.kind == "screenshot"
        assert results.evidence.outcome == "missing"
        refute results.evidence.artifact_ref
        assert results.evidence.commit_sha == @commit

        presented = ScreenshotEvidence.presentation(authority, results.evidence)
        assert presented.capture_result == "inapplicable"
        assert presented.reason == "no_visual_result"
        refute presented.artifact_available?
      end

      test "an environment that cannot capture records unsupported [AC-20]", %{
        authority: authority,
        project: project,
        run: run,
        attempt: attempt
      } do
        assert {:ok, results} =
                 EvidenceIngestion.ingest(
                   authority,
                   project.id,
                   screenshot_event(run, attempt,
                     sequence: 1,
                     capture_result: "unsupported",
                     name: "headless browser unavailable"
                   )
                 )

        assert results.evidence.outcome == "unsupported"
        refute results.evidence.artifact_ref

        presented = ScreenshotEvidence.presentation(authority, results.evidence)
        assert presented.capture_result == "unsupported"
        assert presented.reason == "capture_unsupported"
        refute presented.artifact_available?
      end

      test "a capture that broke records failed with its bounded reason [AC-20]", %{
        authority: authority,
        project: project,
        run: run,
        attempt: attempt
      } do
        assert {:ok, results} =
                 EvidenceIngestion.ingest(
                   authority,
                   project.id,
                   screenshot_event(run, attempt,
                     sequence: 1,
                     capture_result: "failed",
                     name: "board on mobile",
                     command: "capture board --viewport 390x844",
                     exit_code: 3
                   )
                 )

        assert results.evidence.outcome == "failed"
        refute results.evidence.artifact_ref
        assert results.evidence.command == "capture board --viewport 390x844"
        assert results.evidence.exit_code == 3

        presented = ScreenshotEvidence.presentation(authority, results.evidence)
        assert presented.capture_result == "failed"
        assert presented.reason == "capture_failed"
        assert presented.capture_command == "capture board --viewport 390x844"
        refute presented.artifact_available?
      end

      test "the three absences are told apart rather than flattened", %{
        authority: authority,
        project: project,
        run: run,
        attempt: attempt
      } do
        reported = [
          {1, "inapplicable", "missing", "no_visual_result"},
          {2, "unsupported", "unsupported", "capture_unsupported"},
          {3, "failed", "failed", "capture_failed"}
        ]

        for {sequence, capture_result, outcome, reason} <- reported do
          {:ok, results} =
            EvidenceIngestion.ingest(
              authority,
              project.id,
              screenshot_event(run, attempt,
                sequence: sequence,
                capture_result: capture_result,
                name: "shot #{sequence}",
                command: "capture board",
                digest: DeliveryFixtures.digest("absence-#{sequence}")
              )
            )

          assert results.evidence.outcome == outcome
          assert ScreenshotEvidence.presentation(authority, results.evidence).reason == reason
        end
      end

      test "a broken capture with nothing behind it is refused", %{
        authority: authority,
        project: project,
        run: run,
        attempt: attempt
      } do
        assert {:error, :capture_reason_required} =
                 EvidenceIngestion.ingest(
                   authority,
                   project.id,
                   screenshot_event(run, attempt,
                     sequence: 1,
                     capture_result: "failed",
                     command: nil
                   )
                 )

        assert EvidenceIngestion.for_run(authority, project.id, run.id) == []
      end

      test "an unbounded capture reason is refused rather than truncated", %{
        authority: authority,
        project: project,
        run: run,
        attempt: attempt
      } do
        assert {:error, :invalid_evidence} =
                 EvidenceIngestion.ingest(
                   authority,
                   project.id,
                   screenshot_event(run, attempt,
                     sequence: 1,
                     capture_result: "failed",
                     command: String.duplicate("x", Evidence.max_command_bytes() + 1)
                   )
                 )

        assert EvidenceIngestion.for_run(authority, project.id, run.id) == []
      end
    end

    describe "refusing invented evidence (#{authority})" do
      @describetag authority: authority

      test "a capture naming bytes the store does not hold is refused [AC-20]", %{
        authority: authority,
        project: project,
        run: run,
        attempt: attempt
      } do
        # A perfectly well-formed reference for content that was never uploaded.
        never_stored = DeliveryFixtures.digest("never uploaded")

        assert {:error, :artifact_missing} =
                 EvidenceIngestion.ingest(
                   authority,
                   project.id,
                   screenshot_event(run, attempt,
                     sequence: 1,
                     capture_result: "captured",
                     digest: never_stored,
                     artifact_ref: ArtifactStore.ref_for(never_stored)
                   )
                 )

        assert EvidenceIngestion.for_run(authority, project.id, run.id) == []
      end

      test "a capture naming no artifact at all is refused [AC-20]", %{
        authority: authority,
        project: project,
        run: run,
        attempt: attempt
      } do
        assert {:error, :artifact_missing} =
                 EvidenceIngestion.ingest(
                   authority,
                   project.id,
                   screenshot_event(run, attempt,
                     sequence: 1,
                     capture_result: "captured",
                     artifact_ref: nil
                   )
                 )

        assert EvidenceIngestion.for_run(authority, project.id, run.id) == []
      end

      test "a capture whose declared digest addresses other bytes is refused", %{
        authority: authority,
        project: project,
        run: run,
        attempt: attempt
      } do
        capture = store_capture(authority, project)

        assert {:error, :digest_mismatch} =
                 EvidenceIngestion.ingest(
                   authority,
                   project.id,
                   screenshot_event(run, attempt,
                     sequence: 1,
                     capture_result: "captured",
                     digest: DeliveryFixtures.digest("some other picture"),
                     artifact_ref: capture.ref
                   )
                 )

        assert EvidenceIngestion.for_run(authority, project.id, run.id) == []
      end

      test "a redaction claim contradicting the stored artifact is refused", %{
        authority: authority,
        project: project,
        run: run,
        attempt: attempt
      } do
        capture = store_capture(authority, project, redacted: true)

        assert {:error, :redaction_mismatch} =
                 EvidenceIngestion.ingest(
                   authority,
                   project.id,
                   screenshot_event(run, attempt,
                     sequence: 1,
                     capture_result: "captured",
                     digest: capture.digest,
                     artifact_ref: capture.ref,
                     redacted: false
                   )
                 )

        unredacted = store_capture(authority, project, suffix: "plain")

        assert {:error, :redaction_mismatch} =
                 EvidenceIngestion.ingest(
                   authority,
                   project.id,
                   screenshot_event(run, attempt,
                     sequence: 1,
                     capture_result: "captured",
                     digest: unredacted.digest,
                     artifact_ref: unredacted.ref,
                     redacted: true
                   )
                 )

        assert EvidenceIngestion.for_run(authority, project.id, run.id) == []
      end

      test "a worker that never negotiated capture cannot claim one [AC-20]", %{
        authority: authority,
        project: project,
        run: run,
        attempt: attempt
      } do
        # Everything else about this event is correct, including bytes that
        # really are in the store. Only the attached contract disqualifies it.
        capture = store_capture(authority, project)

        attach_worker(
          project.id,
          Enum.reject(WorkerProtocol.capabilities(), &(&1 == ScreenshotEvidence.capability()))
        )

        assert {:error, :capture_unsupported_by_worker} =
                 EvidenceIngestion.ingest(
                   authority,
                   project.id,
                   screenshot_event(run, attempt,
                     sequence: 1,
                     capture_result: "captured",
                     digest: capture.digest,
                     artifact_ref: capture.ref
                   )
                 )

        assert EvidenceIngestion.for_run(authority, project.id, run.id) == []
      end

      test "an absence claim cannot smuggle content [AC-20]", %{
        authority: authority,
        project: project,
        run: run,
        attempt: attempt
      } do
        capture = store_capture(authority, project)

        for capture_result <- ~w(inapplicable unsupported failed) do
          assert {:error, :unexpected_artifact} =
                   EvidenceIngestion.ingest(
                     authority,
                     project.id,
                     screenshot_event(run, attempt,
                       sequence: 1,
                       capture_result: capture_result,
                       command: "capture board",
                       digest: capture.digest,
                       artifact_ref: capture.ref
                     )
                   )
        end

        assert EvidenceIngestion.for_run(authority, project.id, run.id) == []
      end

      test "an unreported or unknown capture result is refused", %{
        authority: authority,
        project: project,
        run: run,
        attempt: attempt
      } do
        for capture_result <- [nil, "", "probably", "captured!", 1] do
          assert {:error, :invalid_capture_result} =
                   EvidenceIngestion.ingest(
                     authority,
                     project.id,
                     screenshot_event(run, attempt,
                       sequence: 1,
                       capture_result: capture_result
                     )
                   )
        end

        assert EvidenceIngestion.for_run(authority, project.id, run.id) == []
      end

      test "a capture that names no commit is refused", %{
        authority: authority,
        project: project,
        run: run,
        attempt: attempt
      } do
        capture = store_capture(authority, project)

        assert {:error, :capture_commit_required} =
                 EvidenceIngestion.ingest(
                   authority,
                   project.id,
                   screenshot_event(run, attempt,
                     sequence: 1,
                     capture_result: "captured",
                     commit_sha: nil,
                     digest: capture.digest,
                     artifact_ref: capture.ref
                   )
                 )

        assert EvidenceIngestion.for_run(authority, project.id, run.id) == []
      end

      test "an agent's account of its own capture is still refused upstream", %{
        authority: authority,
        project: project,
        run: run,
        attempt: attempt
      } do
        capture = store_capture(authority, project)

        assert {:error, :agent_evidence_refused} =
                 EvidenceIngestion.ingest(
                   authority,
                   project.id,
                   screenshot_event(run, attempt,
                     sequence: 1,
                     source: "agent",
                     capture_result: "captured",
                     digest: capture.digest,
                     artifact_ref: capture.ref
                   )
                 )

        assert EvidenceIngestion.for_run(authority, project.id, run.id) == []
      end
    end

    describe "the shared event gate still applies to a capture (#{authority})" do
      @describetag authority: authority

      test "a superseded worker's fence records nothing", %{
        authority: authority,
        project: project,
        run: run,
        attempt: attempt
      } do
        capture = store_capture(authority, project)

        assert {:error, :stale_fence} =
                 EvidenceIngestion.ingest(
                   authority,
                   project.id,
                   screenshot_event(run, attempt,
                     sequence: 1,
                     fence_token: attempt.fence_token + 7,
                     capture_result: "captured",
                     digest: capture.digest,
                     artifact_ref: capture.ref
                   )
                 )

        assert EvidenceIngestion.for_run(authority, project.id, run.id) == []
      end

      test "a replayed capture is a duplicate, not a second screenshot", %{
        authority: authority,
        project: project,
        run: run,
        attempt: attempt
      } do
        capture = store_capture(authority, project)

        envelope =
          screenshot_event(run, attempt,
            sequence: 3,
            capture_result: "captured",
            digest: capture.digest,
            artifact_ref: capture.ref
          )

        {:ok, _first} = EvidenceIngestion.ingest(authority, project.id, envelope)

        assert {:error, :duplicate_event} =
                 EvidenceIngestion.ingest(authority, project.id, envelope)

        assert length(EvidenceIngestion.for_run(authority, project.id, run.id)) == 1
      end

      test "an out-of-order capture is refused", %{
        authority: authority,
        project: project,
        run: run,
        attempt: attempt
      } do
        {:ok, _first} =
          EvidenceIngestion.ingest(
            authority,
            project.id,
            screenshot_event(run, attempt, sequence: 5, capture_result: "inapplicable")
          )

        assert {:error, :stale_sequence} =
                 EvidenceIngestion.ingest(
                   authority,
                   project.id,
                   screenshot_event(run, attempt, sequence: 4, capture_result: "inapplicable")
                 )

        assert length(EvidenceIngestion.for_run(authority, project.id, run.id)) == 1
      end

      test "an oversized capture event never reaches storage", %{
        authority: authority,
        project: project,
        run: run,
        attempt: attempt
      } do
        oversized =
          run
          |> screenshot_event(attempt, sequence: 1, capture_result: "failed")
          |> put_payload("command", String.duplicate("x", 70_000))

        assert {:error, :payload_too_large} =
                 EvidenceIngestion.ingest(authority, project.id, oversized)

        assert EvidenceIngestion.for_run(authority, project.id, run.id) == []
      end
    end

    describe "presentation metadata for one capture (#{authority})" do
      @describetag authority: authority

      test "reports the outcome, artifact availability, and binding a reader needs", %{
        authority: authority,
        project: project,
        run: run,
        attempt: attempt
      } do
        capture = store_capture(authority, project)

        {:ok, results} =
          EvidenceIngestion.ingest(
            authority,
            project.id,
            screenshot_event(run, attempt,
              sequence: 1,
              capture_result: "captured",
              digest: capture.digest,
              artifact_ref: capture.ref
            )
          )

        presented = ScreenshotEvidence.presentation(authority, results.evidence)

        assert presented.evidence_id == results.evidence.id
        assert presented.kind == "screenshot"
        assert presented.outcome == "passed"
        assert presented.capture_result == "captured"
        assert presented.reason == nil
        assert presented.artifact_available?
        assert presented.content_type == "image/png"
        assert presented.byte_size == byte_size(capture.content)
        assert presented.commit_sha == @commit
        assert presented.branch == run.branch
        assert presented.attempt_id == attempt.id
        assert presented.digest == capture.digest
        refute presented.redacted
        refute presented.superseded?
      end

      test "exposes no URL, no reference, and no bytes", %{
        authority: authority,
        project: project,
        run: run,
        attempt: attempt
      } do
        capture = store_capture(authority, project)

        {:ok, results} =
          EvidenceIngestion.ingest(
            authority,
            project.id,
            screenshot_event(run, attempt,
              sequence: 1,
              capture_result: "captured",
              digest: capture.digest,
              artifact_ref: capture.ref
            )
          )

        presented = ScreenshotEvidence.presentation(authority, results.evidence)

        for key <- [:url, :href, :link, :content, :bytes, :artifact_ref, :artifact] do
          refute Map.has_key?(presented, key)
        end

        strings = presented |> Map.values() |> Enum.filter(&is_binary/1)

        refute Enum.any?(strings, &String.contains?(&1, "://"))
        refute Enum.any?(strings, &String.starts_with?(&1, ArtifactStore.ref_prefix()))
        refute Enum.any?(strings, &(&1 == capture.content))
        refute capture.ref in Map.values(presented)
      end

      test "availability is read now, not assumed from the outcome", %{
        authority: authority,
        project: project,
        run: run,
        attempt: attempt
      } do
        capture = store_capture(authority, project)

        {:ok, results} =
          EvidenceIngestion.ingest(
            authority,
            project.id,
            screenshot_event(run, attempt,
              sequence: 1,
              capture_result: "captured",
              digest: capture.digest,
              artifact_ref: capture.ref
            )
          )

        assert ScreenshotEvidence.presentation(authority, results.evidence).artifact_available?

        # Retention or erasure can remove the bytes long after the proof was
        # recorded. A reader must see that rather than a promise that no longer
        # holds; the evidence row itself is never rewritten.
        :ok = ArtifactStore.delete(authority, project.id, capture.ref)

        presented = ScreenshotEvidence.presentation(authority, results.evidence)
        refute presented.artifact_available?
        assert presented.outcome == "passed"
      end

      test "a required check is not a screenshot to present", %{
        authority: authority,
        project: project,
        run: run,
        attempt: attempt
      } do
        {:ok, results} =
          EvidenceIngestion.ingest(
            authority,
            project.id,
            check_event(run, attempt, sequence: 1)
          )

        assert ScreenshotEvidence.presentation(authority, results.evidence) == nil
      end
    end
  end

  describe "the mapping between reported result and recorded outcome" do
    test "each reported result names one existing outcome and adds none" do
      assert ScreenshotEvidence.capture_results() ==
               ~w(captured inapplicable unsupported failed)

      mapped = Enum.map(ScreenshotEvidence.capture_results(), &ScreenshotEvidence.outcome_for/1)

      assert mapped == ~w(passed missing unsupported failed)
      assert Enum.sort(mapped) == Enum.sort(Evidence.outcomes())
    end

    test "the capture capability is the protocol's optional one, not a new name" do
      assert ScreenshotEvidence.capability() in WorkerProtocol.optional_capabilities()
      refute ScreenshotEvidence.capability() in WorkerProtocol.required_capabilities()
    end

    test "the kind is one the evidence table already holds" do
      assert ScreenshotEvidence.kind() in Evidence.kinds()
    end
  end

  defp store_capture(authority, project, opts \\ []) do
    suffix = Keyword.get(opts, :suffix, "capture-#{System.unique_integer([:positive])}")
    content = DeliveryFixtures.png_bytes(suffix)
    redacted = Keyword.get(opts, :redacted, false)

    ref =
      DeliveryFixtures.artifact_fixture(authority, project.id,
        content: content,
        redacted: redacted
      )

    %{content: content, ref: ref, digest: DeliveryFixtures.content_digest(content)}
  end

  # A stand-in for a worker holding one negotiated contract. The registry is
  # global, so the process is killed when the test ends.
  defp attach_worker(project_id, capabilities) do
    test = self()

    worker =
      spawn(fn ->
        {:ok, _registration} =
          Channel.attach(project_id, %{
            worker_id: "worker-#{System.unique_integer([:positive])}",
            protocol_version: WorkerProtocol.version(),
            capabilities: capabilities
          })

        send(test, {:attached, self()})
        Process.sleep(:infinity)
      end)

    assert_receive {:attached, ^worker}
    on_exit(fn -> Process.exit(worker, :kill) end)
    worker
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

  # A screenshot event deliberately carries no `outcome`: the reported capture
  # result is what fixes it, so the two can never be made to disagree on the
  # wire.
  defp screenshot_event(run, attempt, opts) do
    payload = %{
      "kind" => "screenshot",
      "name" => Keyword.get(opts, :name, "board on mobile"),
      "capture_result" => Keyword.get(opts, :capture_result, "captured"),
      "command" => Keyword.get(opts, :command, "capture board"),
      "exit_code" => Keyword.get(opts, :exit_code),
      "duration_ms" => Keyword.get(opts, :duration_ms, 820),
      "commit_sha" => Keyword.get(opts, :commit_sha, @commit),
      "digest" => Keyword.get(opts, :digest, DeliveryFixtures.digest("shot")),
      "redacted" => Keyword.get(opts, :redacted, false),
      "artifact_ref" => Keyword.get(opts, :artifact_ref)
    }

    envelope(run, attempt, payload, Keyword.put_new(opts, :source, "worker"))
  end

  defp check_event(run, attempt, opts) do
    payload = %{
      "kind" => "required_check",
      "name" => "mix test",
      "outcome" => "passed",
      "command" => "mix test",
      "exit_code" => 0,
      "duration_ms" => 4_200,
      "commit_sha" => @commit,
      "digest" => DeliveryFixtures.digest("mix test"),
      "redacted" => false
    }

    envelope(run, attempt, payload, Keyword.put_new(opts, :source, "check"))
  end

  defp envelope(run, attempt, payload, opts) do
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
      "source" => Keyword.fetch!(opts, :source),
      "occurred_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "payload" => payload
    }
  end

  defp put_payload(envelope, key, value),
    do: Map.put(envelope, "payload", Map.put(envelope["payload"], key, value))
end
