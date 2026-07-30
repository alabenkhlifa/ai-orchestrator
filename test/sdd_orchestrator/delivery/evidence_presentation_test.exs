defmodule SddOrchestrator.Delivery.EvidencePresentationTest do
  @moduledoc """
  Proof for presenting verification evidence (Task 31, AC-40).

  The requirement is not that evidence can be listed. It is that a person who
  was not there can decide whether to trust a completion claim, which means four
  things have to hold at once.

  Every item says what kind of proof it is and which of the four recorded
  outcomes it reached, so `missing` and `unsupported` can never be read as a
  pass. Every item carries the run, attempt, branch, commit, source, instant,
  duration, digest, and redaction state it was recorded with, because provenance
  that is stored but not shown proves nothing to a reader. Nothing is filtered:
  a result a later run replaced stays in the list and says so, and a refused
  verification names the checks that failed or never reported. And the bytes
  behind a screenshot reach a person only through the authorized fetch seam,
  which answers a stranger, another project's item, an unknown item, and an item
  that never had bytes identically.

  Every behaviour runs against both storage authorities, because `specs/05`
  forbids keeping a device-authoritative project's evidence in the hosted
  database and two implementations are only safe once they answer the same way.
  """
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Accounts.DeviceWorkspace
  alias SddOrchestrator.Delivery.{ArtifactStore, EvidencePresentation}
  alias SddOrchestrator.Delivery.VerificationCompletion.Verdict
  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.DeviceStore.Local
  alias SddOrchestrator.EvidencePresentationFixtures, as: Fixtures
  alias SddOrchestrator.Participation.Revocations

  setup context do
    hosted = DeliveryFixtures.delivery_project_fixture()
    feature = DeliveryFixtures.feature_fixture(hosted.project, hosted.account)

    path = Path.join(System.tmp_dir!(), "presentation-#{System.unique_integer([:positive])}.dets")
    start_supervised!({Local, path: path})
    on_exit(fn -> File.rm_rf(path) end)

    {:ok, device_workspace} = Devices.establish_workspace()

    authority =
      case context[:authority] do
        :device -> %DeviceWorkspace{id: device_workspace.id}
        _hosted -> hosted.workspace
      end

    run = Fixtures.run_fixture(authority, hosted.project, feature)

    %{
      authority: authority,
      context: hosted,
      project: hosted.project,
      account: hosted.account,
      actor: hosted.owner_actor,
      feature: feature,
      run: run
    }
  end

  for authority <- [:hosted, :device] do
    describe "listing what a feature has proved (#{authority})" do
      @describetag authority: authority

      test "returns every recorded item in the order the store holds it [AC-40]", ctx do
        first = Fixtures.evidence_fixture(ctx.authority, ctx.run, name: "mix test")
        second = Fixtures.evidence_fixture(ctx.authority, ctx.run, name: "mix credo")
        third = Fixtures.evidence_fixture(ctx.authority, ctx.run, name: "mix dialyzer")

        assert {:ok, items} = list(ctx)

        assert Enum.map(items, & &1.id) == [first.id, second.id, third.id]
        assert Enum.map(items, & &1.name) == ["mix test", "mix credo", "mix dialyzer"]
      end

      test "shows only the feature that was asked for", ctx do
        other_feature = DeliveryFixtures.feature_fixture(ctx.project, ctx.account)
        other_run = Fixtures.run_fixture(ctx.authority, ctx.project, other_feature)

        mine = Fixtures.evidence_fixture(ctx.authority, ctx.run, name: "mix test")
        _theirs = Fixtures.evidence_fixture(ctx.authority, other_run, name: "mix format")

        assert {:ok, [item]} = list(ctx)
        assert item.id == mine.id
      end

      test "a feature that has proved nothing lists nothing rather than failing", ctx do
        assert {:ok, []} = list(ctx)
      end
    end

    describe "who may read it (#{authority})" do
      @describetag authority: authority

      test "a stranger to the project is refused [AC-40]", ctx do
        Fixtures.evidence_fixture(ctx.authority, ctx.run, name: "mix test")
        outsider = SddOrchestrator.AccountsFixtures.account_fixture()
        actor = %{account_id: outsider.id, hosted_identity_id: nil}

        assert {:error, :unauthorized} =
                 EvidencePresentation.list(
                   ctx.authority,
                   ctx.project.id,
                   actor,
                   ctx.feature.id
                 )

        assert {:error, :unauthorized} =
                 EvidencePresentation.verification(
                   ctx.authority,
                   ctx.project.id,
                   actor,
                   ctx.feature.id
                 )
      end

      test "a participant who was removed is refused on the next read [AC-40]", ctx do
        Fixtures.evidence_fixture(ctx.authority, ctx.run, name: "mix test")
        actor = ctx.context.participant_actor

        assert {:ok, [_item]} =
                 EvidencePresentation.list(ctx.authority, ctx.project.id, actor, ctx.feature.id)

        {:ok, _removed} =
          Revocations.remove(
            ctx.project,
            ctx.account.id,
            ctx.context.identity.hosted_identity.id
          )

        assert {:error, :unauthorized} =
                 EvidencePresentation.list(ctx.authority, ctx.project.id, actor, ctx.feature.id)
      end
    end

    describe "the state one item reached (#{authority})" do
      @describetag authority: authority

      test "each recorded outcome is presented as its own state [AC-40]", ctx do
        for {name, outcome} <- [
              {"mix test", "passed"},
              {"mix credo", "failed"},
              {"mix dialyzer", "missing"},
              {"mix sobelow", "unsupported"}
            ] do
          Fixtures.evidence_fixture(ctx.authority, ctx.run,
            name: name,
            outcome: outcome,
            exit_code: if(outcome == "passed", do: 0, else: 1)
          )
        end

        assert {:ok, items} = list(ctx)

        assert Map.new(items, &{&1.name, &1.outcome}) == %{
                 "mix test" => "passed",
                 "mix credo" => "failed",
                 "mix dialyzer" => "missing",
                 "mix sobelow" => "unsupported"
               }

        # None of the four is also reported as replaced, so a reader can tell a
        # current absence from a superseded one.
        assert Enum.all?(items, &(&1.superseded? == false))
      end

      test "a screenshot keeps its typed absence reason rather than reading as a pass", ctx do
        Fixtures.evidence_fixture(ctx.authority, ctx.run,
          kind: "screenshot",
          name: "no visual change",
          outcome: "missing",
          source: "worker"
        )

        assert {:ok, [item]} = list(ctx)

        assert item.kind == "screenshot"
        assert item.outcome == "missing"
        assert item.capture_result == "inapplicable"
        assert item.capture_reason == "no_visual_result"
        refute item.artifact_available?
      end

      test "a capture the environment could not run is unsupported, not missing", ctx do
        Fixtures.evidence_fixture(ctx.authority, ctx.run,
          kind: "screenshot",
          name: "headless capture",
          outcome: "unsupported",
          source: "worker"
        )

        assert {:ok, [item]} = list(ctx)

        assert item.outcome == "unsupported"
        assert item.capture_reason == "capture_unsupported"
      end
    end

    describe "the provenance one item carries (#{authority})" do
      @describetag authority: authority

      test "reports the run, attempt, branch, commit, source, time and duration [AC-40]", ctx do
        recorded_at = ~U[2026-07-30 09:15:00.000000Z]

        evidence =
          Fixtures.evidence_fixture(ctx.authority, ctx.run,
            name: "mix test",
            duration_ms: 12_500,
            recorded_at: recorded_at,
            source: "worker"
          )

        assert {:ok, [item]} = list(ctx)

        assert item.run_id == ctx.run.run.id
        assert item.attempt_id == ctx.run.attempt.id
        assert item.run_ref == EvidencePresentation.short_reference(ctx.run.run.id)
        assert item.attempt_ref == EvidencePresentation.short_reference(ctx.run.attempt.id)
        assert item.branch == ctx.run.run.branch
        assert item.commit_sha == Fixtures.commit()
        assert item.source == "worker"
        assert item.recorded_at == recorded_at
        assert item.duration_ms == 12_500
        assert item.command == "mix test"
        assert item.exit_code == 0
        assert item.digest == evidence.digest
      end

      test "reports the redaction state the record was written with [AC-40]", ctx do
        Fixtures.evidence_fixture(ctx.authority, ctx.run, name: "plain", redacted: false)
        Fixtures.evidence_fixture(ctx.authority, ctx.run, name: "cleaned", redacted: true)

        assert {:ok, items} = list(ctx)
        assert Map.new(items, &{&1.name, &1.redacted}) == %{"plain" => false, "cleaned" => true}
      end

      test "never hands the caller an artifact reference [AC-40]", ctx do
        Fixtures.screenshot_fixture(ctx.authority, ctx.run, name: "board")

        assert {:ok, [item]} = list(ctx)
        refute Map.has_key?(item, :artifact_ref)

        assert item
               |> Map.values()
               |> Enum.filter(&is_binary/1)
               |> Enum.all?(&(not String.contains?(&1, ArtifactStore.ref_prefix())))
      end
    end

    describe "a result a later run replaced (#{authority})" do
      @describetag authority: authority

      test "stays visible and says what replaced it [AC-40]", ctx do
        failed =
          Fixtures.evidence_fixture(ctx.authority, ctx.run,
            name: "mix test",
            outcome: "failed",
            exit_code: 1
          )

        passed =
          Fixtures.evidence_fixture(ctx.authority, ctx.run, name: "mix test", outcome: "passed")

        :ok = Fixtures.supersede_fixture(ctx.authority, failed, passed)

        assert {:ok, [replaced, replacement]} = list(ctx)

        assert replaced.id == failed.id
        assert replaced.superseded? == true
        assert replaced.outcome == "failed"
        assert replaced.replaced_by_ref == EvidencePresentation.short_reference(passed.id)

        assert replacement.id == passed.id
        assert replacement.superseded? == false
        assert replacement.replaced_by_ref == nil
      end
    end

    describe "the bytes behind a screenshot (#{authority})" do
      @describetag authority: authority

      test "an item reports that it holds bytes without naming them [AC-40]", ctx do
        Fixtures.screenshot_fixture(ctx.authority, ctx.run, name: "board")

        assert {:ok, [item]} = list(ctx)

        assert item.artifact_available? == true
        assert item.content_type == "image/png"
        assert item.byte_size > 0
      end

      test "a current participant receives the content itself, never a location", ctx do
        content = DeliveryFixtures.png_bytes("inline")

        evidence =
          Fixtures.screenshot_fixture(ctx.authority, ctx.run, name: "board", content: content)

        assert {:ok, artifact} =
                 EvidencePresentation.inline_artifact(
                   ctx.authority,
                   ctx.project.id,
                   evidence.id,
                   ctx.actor
                 )

        assert artifact.content_type == "image/png"
        assert artifact.inline? == true
        assert artifact.data == "data:image/png;base64,#{Base.encode64(content)}"
        assert artifact.digest == DeliveryFixtures.content_digest(content)
        refute String.contains?(artifact.data, ArtifactStore.ref_prefix())
      end

      test "a stranger is answered exactly like an absence [AC-40]", ctx do
        evidence = Fixtures.screenshot_fixture(ctx.authority, ctx.run, name: "board")
        outsider = SddOrchestrator.AccountsFixtures.account_fixture()

        assert {:error, :not_found} =
                 EvidencePresentation.inline_artifact(
                   ctx.authority,
                   ctx.project.id,
                   evidence.id,
                   %{account_id: outsider.id, hosted_identity_id: nil}
                 )
      end

      test "a participant who was removed loses the bytes immediately", ctx do
        evidence = Fixtures.screenshot_fixture(ctx.authority, ctx.run, name: "board")
        actor = ctx.context.participant_actor

        assert {:ok, _artifact} =
                 EvidencePresentation.inline_artifact(
                   ctx.authority,
                   ctx.project.id,
                   evidence.id,
                   actor
                 )

        {:ok, _removed} =
          Revocations.remove(
            ctx.project,
            ctx.account.id,
            ctx.context.identity.hosted_identity.id
          )

        assert {:error, :not_found} =
                 EvidencePresentation.inline_artifact(
                   ctx.authority,
                   ctx.project.id,
                   evidence.id,
                   actor
                 )
      end

      test "an item that never held bytes is answered like an unknown one", ctx do
        evidence = Fixtures.evidence_fixture(ctx.authority, ctx.run, name: "mix test")

        assert {:error, :not_found} =
                 EvidencePresentation.inline_artifact(
                   ctx.authority,
                   ctx.project.id,
                   evidence.id,
                   ctx.actor
                 )

        assert {:error, :not_found} =
                 EvidencePresentation.inline_artifact(
                   ctx.authority,
                   ctx.project.id,
                   Ecto.UUID.generate(),
                   ctx.actor
                 )
      end

      test "an item belonging to another project is answered like an absence", ctx do
        other = DeliveryFixtures.delivery_project_fixture()
        other_feature = DeliveryFixtures.feature_fixture(other.project, other.account)
        other_run = Fixtures.run_fixture(other.workspace, other.project, other_feature)
        evidence = Fixtures.screenshot_fixture(other.workspace, other_run, name: "theirs")

        assert {:error, :not_found} =
                 EvidencePresentation.inline_artifact(
                   ctx.authority,
                   ctx.project.id,
                   evidence.id,
                   ctx.actor
                 )
      end

      test "stored proof that is not an image is described rather than shown", ctx do
        content = "mix test\n1 doctest, 12 tests, 0 failures\n"

        ref =
          DeliveryFixtures.artifact_fixture(ctx.authority, ctx.project.id,
            content: content,
            content_type: "text/plain"
          )

        evidence =
          Fixtures.evidence_fixture(ctx.authority, ctx.run,
            name: "mix test",
            digest: DeliveryFixtures.content_digest(content),
            artifact_ref: ref
          )

        assert {:ok, [item]} = list(ctx)
        assert item.artifact_available? == true
        assert item.content_type == "text/plain"

        assert {:ok, artifact} =
                 EvidencePresentation.inline_artifact(
                   ctx.authority,
                   ctx.project.id,
                   evidence.id,
                   ctx.actor
                 )

        assert artifact.inline? == false
        assert artifact.data == nil
      end
    end

    describe "what the completion gate concluded (#{authority})" do
      @describetag authority: authority

      test "a refusal names the checks that failed and the ones with no result [AC-40]", ctx do
        verdict =
          Fixtures.refused_verdict(ctx.run,
            reason: :required_check_failed,
            required: ["mix test", "mix credo", "mix dialyzer"],
            passed: ["mix test"],
            failed: ["mix credo"],
            missing: ["mix dialyzer"]
          )

        Fixtures.verdict_fixture(ctx.authority, ctx.run, verdict)

        assert {:ok, summary} = verification(ctx)

        refute summary.verified?
        assert summary.reason == "required_check_failed"
        assert summary.failed == ["mix credo"]
        assert summary.missing == ["mix dialyzer"]
        assert summary.required_count == 3
        assert summary.passed_count == 1
        assert summary.branch == ctx.run.run.branch
        assert summary.commit_sha == Fixtures.commit()
      end

      test "a refusal over an environment that could not run a check says so", ctx do
        verdict =
          Fixtures.refused_verdict(ctx.run,
            reason: :required_check_unsupported,
            required: ["mix dialyzer"],
            unsupported: ["mix dialyzer"]
          )

        Fixtures.verdict_fixture(ctx.authority, ctx.run, verdict)

        assert {:ok, summary} = verification(ctx)
        assert summary.reason == "required_check_unsupported"
        assert summary.unsupported == ["mix dialyzer"]
      end

      test "a verified completion is presented as verified", ctx do
        verdict = %Verdict{
          outcome: :verified,
          run_id: ctx.run.run.id,
          attempt_id: ctx.run.attempt.id,
          attempt_number: 1,
          branch: ctx.run.run.branch,
          commit_sha: Fixtures.commit(),
          required: ["mix test"],
          passed: ["mix test"]
        }

        Fixtures.verdict_fixture(ctx.authority, ctx.run, verdict)

        assert {:ok, summary} = verification(ctx)

        assert summary.verified?
        assert summary.reason == nil
        assert summary.failed == []
        assert summary.passed_count == 1
      end

      test "the most recent conclusion is the one presented", ctx do
        Fixtures.verdict_fixture(
          ctx.authority,
          ctx.run,
          Fixtures.refused_verdict(ctx.run, required: ["mix test"], failed: ["mix test"])
        )

        Fixtures.verdict_fixture(ctx.authority, ctx.run, %Verdict{
          outcome: :verified,
          run_id: ctx.run.run.id,
          attempt_id: ctx.run.attempt.id,
          attempt_number: 1,
          branch: ctx.run.run.branch,
          commit_sha: Fixtures.commit(),
          required: ["mix test"],
          passed: ["mix test"]
        })

        assert {:ok, summary} = verification(ctx)
        assert summary.verified?
      end

      test "a feature nobody has claimed completion for has no conclusion", ctx do
        assert {:ok, nil} = verification(ctx)
      end
    end
  end

  defp list(ctx),
    do: EvidencePresentation.list(ctx.authority, ctx.project.id, ctx.actor, ctx.feature.id)

  defp verification(ctx),
    do:
      EvidencePresentation.verification(ctx.authority, ctx.project.id, ctx.actor, ctx.feature.id)
end
