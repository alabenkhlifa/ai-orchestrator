defmodule SddOrchestrator.ProjectAssistant.TurnOrchestratorTest do
  @moduledoc """
  specs/12-project-assistant Task 7 focused proof: grounded answers, exact
  citations, and explicit uncertainty (AC-10, AC-11, AC-12).

  Covers one test per citation type (specification, board, run, evidence,
  repository) including a stale/superseded, fabricated, and inaccessible
  variant where applicable; one test per uncertainty marker (partial,
  stale, excluded, unavailable, conflicting, unstable); a worker-offline
  turn that still answers from current stored project data only; a changed
  tree that never yields a stable citation; an inaccessible citation
  failing closed; an uncited material claim being rejected; and normalized
  answer-failure recovery.
  """
  use SddOrchestrator.DataCase, async: false

  import SddOrchestrator.AIRuntimeFixtures

  alias SddOrchestrator.Delivery.DeliveryStore
  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.DeviceStore.Local
  alias SddOrchestrator.EvidencePresentationFixtures, as: EF
  alias SddOrchestrator.ProjectAssistant.BoundaryGate
  alias SddOrchestrator.ProjectAssistant.FakeModelCompletionAdapter
  alias SddOrchestrator.ProjectAssistant.FakeRepositoryObservationAdapter
  alias SddOrchestrator.ProjectAssistant.TurnOrchestrator
  alias SddOrchestrator.Projects.Project
  alias SddOrchestrator.Projects.RepositoryConnection
  alias SddOrchestrator.SpecificationFixtures
  alias SddOrchestrator.SpecificationStore

  @now ~U[2026-08-03 12:00:00Z]

  describe "hosted authority" do
    setup do
      fixture = DeliveryFixtures.delivery_project_fixture()
      feature = DeliveryFixtures.feature_fixture(fixture.project, fixture.account)

      specification =
        SpecificationFixtures.hosted_specification(fixture.workspace, fixture.project, %{
          title: "Read-only project assistant"
        })

      %{run: run, attempt: attempt} = EF.run_fixture(fixture.workspace, fixture.project, feature)
      start_run_activity(fixture.workspace, run, attempt)
      evidence = EF.evidence_fixture(fixture.workspace, %{run: run, attempt: attempt})

      context = runtime_session_context_fixture(%{account: fixture.account, now: @now})

      confirm!(fixture.workspace, fixture.project.id, fixture.owner_actor, fixture.account)

      Map.merge(fixture, %{
        feature: feature,
        specification: specification,
        run: run,
        evidence: evidence,
        context: context
      })
    end

    test "a specification citation resolves to the current revision", %{
      project: project,
      workspace: workspace,
      owner_actor: actor,
      account: account
    } do
      assert {:ok, {_conversation, turn, citations}} =
               ask(workspace, project.id, actor, account, "spec-valid: what spec is current?")

      assert turn.outcome == "answered"
      assert turn.uncertainty_markers == []
      assert [citation] = citations
      assert citation.source_type == "specification"

      # The feature carries a specification of its own, so the model cites
      # whichever one the snapshot lists first. What this proves is unchanged:
      # the citation names a real specification of this project and its current
      # revision, and the answer text names that same specification.
      assert {:ok, cited} =
               SpecificationStore.get_current(
                 workspace,
                 project.id,
                 citation.reference["specification_id"]
               )

      assert citation.reference["revision_id"] == cited.revision.id
      assert turn.answer_text =~ cited.specification.title
    end

    test "a stale specification citation is rejected and marked stale", %{
      project: project,
      workspace: workspace,
      owner_actor: actor,
      account: account
    } do
      assert {:ok, {_conversation, turn, citations}} =
               ask(workspace, project.id, actor, account, "spec-stale: what spec is current?")

      assert citations == []
      assert turn.answer_text == nil
      assert [%{"type" => "stale"}] = turn.uncertainty_markers
    end

    test "a fabricated specification citation is rejected", %{
      project: project,
      workspace: workspace,
      owner_actor: actor,
      account: account
    } do
      assert {:ok, {_conversation, turn, citations}} =
               ask(workspace, project.id, actor, account, "spec-fabricated: made up")

      assert citations == []
      assert [%{"type" => "excluded"}] = turn.uncertainty_markers
    end

    test "a board citation resolves to the current feature", %{
      project: project,
      workspace: workspace,
      owner_actor: actor,
      account: account,
      feature: feature
    } do
      assert {:ok, {_conversation, turn, citations}} =
               ask(workspace, project.id, actor, account, "board-valid: what feature exists?")

      assert turn.uncertainty_markers == []
      assert [citation] = citations
      assert citation.source_type == "board"
      assert citation.reference["feature_id"] == feature.id
    end

    test "a fabricated board citation is rejected", %{
      project: project,
      workspace: workspace,
      owner_actor: actor,
      account: account
    } do
      assert {:ok, {_conversation, turn, citations}} =
               ask(workspace, project.id, actor, account, "board-fabricated: made up")

      assert citations == []
      assert [%{"type" => "excluded"}] = turn.uncertainty_markers
    end

    test "a run citation resolves to the current recent run", %{
      project: project,
      workspace: workspace,
      owner_actor: actor,
      account: account,
      run: run
    } do
      assert {:ok, {_conversation, turn, citations}} =
               ask(workspace, project.id, actor, account, "run-valid: what is the run state?")

      assert turn.uncertainty_markers == []
      assert [citation] = citations
      assert citation.source_type == "run"
      assert citation.reference["run_id"] == run.id
    end

    test "an evidence citation resolves to the current accepted evidence", %{
      project: project,
      workspace: workspace,
      owner_actor: actor,
      account: account,
      evidence: evidence
    } do
      assert {:ok, {_conversation, turn, citations}} =
               ask(workspace, project.id, actor, account, "evidence-valid: what passed?")

      assert turn.uncertainty_markers == []
      assert [citation] = citations
      assert citation.source_type == "evidence"
      assert citation.reference["evidence_id"] == evidence.id
    end

    test "a repository citation resolves against a stable current observation", %{
      project: project,
      workspace: workspace,
      owner_actor: actor,
      account: account
    } do
      project = with_repository_ref(project, "clean")

      assert {:ok, {_conversation, turn, citations}} =
               ask(
                 workspace,
                 project.id,
                 actor,
                 account,
                 "repository-valid: what does the code say?",
                 adapter: FakeRepositoryObservationAdapter,
                 worker_available: always_available()
               )

      assert turn.uncertainty_markers == []
      assert [citation] = citations
      assert citation.source_type == "repository"
      assert citation.reference["path"] == "lib/app.ex"
      assert citation.reference["start_line"] == 1
      assert citation.reference["end_line"] == 2
      assert citation.reference["branch"] == "main"
      assert citation.reference["commit"] == "abc123def456"
      assert citation.reference["stable"] == true
      assert citation.excerpt =~ "line 1 of lib/app.ex"
    end

    test "specs/12 Task 9: a credential pasted into the question never reaches the model or the persisted answer (AC-19)",
         %{
           project: project,
           workspace: workspace,
           owner_actor: actor,
           account: account
         } do
      assert {:ok, {_conversation, turn, _citations}} =
               ask(
                 workspace,
                 project.id,
                 actor,
                 account,
                 "echo-question: my token is sk-aaaaaaaaaaaaaaaaaaaaaaaa"
               )

      refute turn.answer_text =~ "sk-aaaaaaaaaaaaaaaaaaaaaaaa"
      assert turn.answer_text =~ "[redacted]"
    end

    test "specs/12 Task 9: a citation excerpt is redacted even when the path itself was never denied (AC-19)",
         %{
           project: project,
           workspace: workspace,
           owner_actor: actor,
           account: account
         } do
      project = with_repository_ref(project, "clean")

      assert {:ok, {_conversation, _turn, citations}} =
               ask(
                 workspace,
                 project.id,
                 actor,
                 account,
                 "repository-secret-content: what does the code say?",
                 adapter: FakeRepositoryObservationAdapter,
                 worker_available: always_available()
               )

      assert [citation] = citations
      assert citation.source_type == "repository"
      refute citation.excerpt =~ "AKIAABCDEFGHIJKLMNOP"
      assert citation.excerpt =~ "[redacted]"
    end

    test "a changed tree during observation never yields a stable citation", %{
      project: project,
      workspace: workspace,
      owner_actor: actor,
      account: account
    } do
      project = with_repository_ref(project, "unstable")

      assert {:ok, {_conversation, turn, citations}} =
               ask(
                 workspace,
                 project.id,
                 actor,
                 account,
                 "repository-valid: what does the code say?",
                 adapter: FakeRepositoryObservationAdapter,
                 worker_available: always_available()
               )

      assert citations == []
      assert [%{"type" => "unstable"}] = turn.uncertainty_markers
    end

    test "the worker offline still answers from current stored project data only (AC-10)", %{
      project: project,
      workspace: workspace,
      owner_actor: actor,
      account: account
    } do
      project = with_repository_ref(project, "clean")

      assert {:ok, {_conversation, turn, citations}} =
               ask(workspace, project.id, actor, account, "mixed: what is current?",
                 adapter: FakeRepositoryObservationAdapter,
                 worker_available: fn _authority, _project_id -> false end
               )

      assert [citation] = citations
      assert citation.source_type == "specification"
      refute Enum.any?(citations, &(&1.source_type == "repository"))

      # The feature carries a specification of its own, so the model cites
      # whichever one the snapshot lists first. What this proves is unchanged:
      # the answer came from stored project data, naming the specification it
      # actually cited, and nothing from the offline worker's repository.
      assert {:ok, cited} =
               SpecificationStore.get_current(
                 workspace,
                 project.id,
                 citation.reference["specification_id"]
               )

      assert citation.reference["revision_id"] == cited.revision.id
      assert turn.answer_text =~ cited.specification.title
      refute turn.answer_text =~ "lib/app.ex"
      assert [%{"type" => "unavailable"}] = turn.uncertainty_markers
    end

    test "an inaccessible (denied-path) repository citation fails closed", %{
      project: project,
      workspace: workspace,
      owner_actor: actor,
      account: account
    } do
      project = with_repository_ref(project, "clean")

      assert {:ok, {_conversation, turn, citations}} =
               ask(workspace, project.id, actor, account, "repository-secret: what is in .env?",
                 adapter: FakeRepositoryObservationAdapter,
                 worker_available: always_available()
               )

      assert citations == []
      assert [%{"type" => "excluded"}] = turn.uncertainty_markers
    end

    test "an uncited material claim is rejected rather than shown as fact", %{
      project: project,
      workspace: workspace,
      owner_actor: actor,
      account: account
    } do
      assert {:ok, {_conversation, turn, citations}} =
               ask(workspace, project.id, actor, account, "uncited-material: tell me a fact")

      assert citations == []
      assert turn.answer_text == nil
      assert [%{"type" => "excluded"}] = turn.uncertainty_markers
    end

    test "a candidate-declared conflicting marker is preserved alongside its resolved claims", %{
      project: project,
      workspace: workspace,
      owner_actor: actor,
      account: account
    } do
      assert {:ok, {_conversation, turn, citations}} =
               ask(workspace, project.id, actor, account, "conflicting: which is right?")

      assert length(citations) == 2
      assert [%{"type" => "conflicting", "detail" => detail}] = turn.uncertainty_markers
      assert detail =~ "differently"
    end

    test "a candidate-declared partial marker is preserved", %{
      project: project,
      workspace: workspace,
      owner_actor: actor,
      account: account
    } do
      assert {:ok, {_conversation, turn, citations}} =
               ask(workspace, project.id, actor, account, "partial: how much can you answer?")

      assert length(citations) == 1
      assert [%{"type" => "partial"}] = turn.uncertainty_markers
    end

    test "answer failure recovery normalizes a model failure and still persists the turn", %{
      project: project,
      workspace: workspace,
      owner_actor: actor,
      account: account
    } do
      assert {:ok, {_conversation, turn, citations}} =
               ask(workspace, project.id, actor, account, "fails: timeout")

      assert turn.outcome == "failed"
      assert turn.failure_reason == "timeout"
      assert turn.answer_text == nil
      assert citations == []
      assert turn.uncertainty_markers == []
    end

    test "an unconfirmed participant is refused before any turn is persisted (AC-05)", %{
      project: project,
      workspace: workspace,
      participant_actor: participant_actor,
      account: account
    } do
      # `participant_actor` is a current, valid project participant (added by
      # `DeliveryFixtures.delivery_project_fixture/0`) but never confirmed
      # this processing boundary themselves, so the pre-tool gate refuses
      # before any read tool or model call runs, and no turn is persisted.
      assert {:error, :confirmation_required} =
               TurnOrchestrator.answer(
                 workspace,
                 project.id,
                 participant_actor,
                 account,
                 "spec-valid: anything",
                 now: @now,
                 model_adapter: FakeModelCompletionAdapter
               )

      assert {:ok, nil, []} =
               SddOrchestrator.ProjectAssistantStore.list_history(
                 workspace,
                 project.id,
                 participant_actor
               )
    end
  end

  describe "device authority" do
    setup do
      path =
        Path.join(
          System.tmp_dir!(),
          "turn_orchestrator_device_store_#{System.unique_integer([:positive])}/store.dets"
        )

      on_exit(fn -> File.rm_rf!(Path.dirname(path)) end)
      start_supervised!({Local, path: path})

      {:ok, workspace} = Devices.establish_workspace()

      {:ok, project} =
        Devices.register_project(%{
          name: "Device assistant project",
          repository_fingerprint:
            "device-orchestrator-fingerprint-#{System.unique_integer([:positive])}",
          status: "connected",
          idempotency_key: Ecto.UUID.generate()
        })

      feature = plant_device_feature(project.id)

      {:ok, specification} =
        SddOrchestrator.SpecificationStore.create(
          workspace,
          project.id,
          SpecificationFixtures.specification_attrs(%{title: "Device assistant spec"}),
          actor_ref: "owner"
        )

      context = runtime_session_context_fixture(%{now: @now})
      confirm!(workspace, project.id, %{}, context.account)

      %{
        workspace: workspace,
        project: project,
        feature: feature,
        specification: specification,
        account: context.account
      }
    end

    test "a specification citation resolves and persists through the device store", %{
      project: project,
      workspace: workspace,
      account: account,
      specification: specification
    } do
      assert {:ok, {_conversation, turn, citations}} =
               ask(workspace, project.id, %{}, account, "spec-valid: what spec is current?")

      assert turn.outcome == "answered"
      assert [citation] = citations
      assert citation.source_type == "specification"
      assert citation.reference["specification_id"] == specification.specification.id
      assert citation.reference["revision_id"] == specification.revision.id
    end

    test "the worker offline still answers from current stored project data only (AC-10)", %{
      project: project,
      workspace: workspace,
      account: account
    } do
      assert {:ok, {_conversation, turn, citations}} =
               ask(workspace, project.id, %{}, account, "mixed: what is current?",
                 adapter: FakeRepositoryObservationAdapter,
                 worker_available: fn _authority, _project_id -> false end
               )

      assert [citation] = citations
      assert citation.source_type == "specification"
      assert [%{"type" => "unavailable"}] = turn.uncertainty_markers
    end
  end

  defp always_available, do: fn _authority, _project_id -> true end

  # Naming a `test` provider replaces whatever repository the project had, so
  # the connection that came with it goes too. Leaving a GitHub connection
  # attached would send `RepositorySourceAuthorization` down its GitHub branch
  # while the project claims a different provider, and the observation would be
  # refused for a reason the test is not about.
  defp with_repository_ref(project, ref) do
    Repo.delete_all(from c in RepositoryConnection, where: c.project_id == ^project.id)

    {:ok, updated} =
      project
      |> Project.changeset(%{repository_provider: "test", canonical_repository_id: ref})
      |> Repo.update()

    Repo.preload(updated, :repository_connection, force: true)
  end

  defp confirm!(workspace, project_id, actor, account) do
    assert {:ok, _confirmation} =
             BoundaryGate.confirm(workspace, project_id, actor, account, now: @now)
  end

  defp ask(workspace, project_id, actor, account, question_text, opts \\ []) do
    TurnOrchestrator.answer(
      workspace,
      project_id,
      actor,
      account,
      question_text,
      Keyword.merge([now: @now, model_adapter: FakeModelCompletionAdapter], opts)
    )
  end

  # `EvidencePresentationFixtures.run_fixture/3` deliberately does not append
  # a "run_started" activity entry; this appends the one entry
  # `ProjectContextAssembler` reads to find one feature's current run,
  # mirroring `ProjectContextStoreTest`'s own identical helper.
  defp start_run_activity(authority, run, attempt) do
    {:ok, %{activity: entry}} =
      DeliveryStore.commit(authority, run.project_id, [
        {:activity,
         {:append_activity,
          %{
            project_id: run.project_id,
            feature_id: run.feature_id,
            run_id: run.id,
            attempt_id: attempt.id,
            actor_kind: "system",
            type: "run_started",
            payload: %{}
          }}}
      ])

    entry
  end

  # Mirrors `ProjectContextStoreTest`'s identical device-feature planting
  # helper: a device-authoritative project has no hosted `Features.create/3`
  # path, so this plants one directly through the same generic
  # device-delivery seam production code will eventually write through.
  defp plant_device_feature(project_id) do
    feature = %SddOrchestrator.Delivery.Feature{
      id: Ecto.UUID.generate(),
      project_id: project_id,
      title: "Device feature",
      creator_account_id: nil,
      assigned_account_id: nil
    }

    {:ok, _applied} =
      Devices.commit_delivery(project_id, [
        {:put, :feature, feature.id, SddOrchestrator.Delivery.Feature.to_value(feature), nil}
      ])

    feature
  end
end
