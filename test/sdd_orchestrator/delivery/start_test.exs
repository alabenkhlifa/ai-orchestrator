defmodule SddOrchestrator.Delivery.StartTest do
  @moduledoc """
  Proof for explicit development start (Task 13).

  Starting is the moment the product commits to consequential, costly work, so
  the tests pin what must be true at that instant rather than what was true
  when the button was drawn: current participation, current readiness against
  the revision actually in play, and a confirmed processing boundary. They also
  pin that nothing starts by itself and that nothing starts twice.
  """
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Accounts.DeviceWorkspace

  alias SddOrchestrator.Delivery.{
    ActivityEntry,
    AgentRun,
    ExecutionManifest,
    Feature,
    ProcessingDisclosure,
    Readiness,
    RunAttempt,
    RunCommand,
    Start,
    Suggestions
  }

  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.Participation.Revocations
  alias SddOrchestrator.ParticipationDeliveryDouble
  alias SddOrchestrator.ReadinessGuidanceDouble
  alias SddOrchestrator.Repo
  alias SddOrchestrator.SpecificationFixtures
  alias SddOrchestrator.SpecificationStore

  @execution [
    approved_slice: "slice-07",
    repository_base_revision: "a1b2c3d4e5f6a7b8",
    required_checks: [%{"name" => "mix test", "command" => "mix test"}],
    agent_ref: %{"provider" => "configured-agent"},
    worker_ref: %{"target" => "configured-worker"}
  ]

  @boundary [
    execution_location: "this computer",
    agent_provider: "configured-agent",
    model_provider: "configured-model",
    transfers: []
  ]

  setup do
    restore = ReadinessGuidanceDouble.install()
    on_exit(restore)

    for {key, value} <- [
          participation_email_delivery: ParticipationDeliveryDouble,
          delivery_execution: @execution,
          processing_boundary: @boundary
        ] do
      previous = Application.get_env(:sdd_orchestrator, key)
      Application.put_env(:sdd_orchestrator, key, value)

      on_exit(fn ->
        if previous do
          Application.put_env(:sdd_orchestrator, key, previous)
        else
          Application.delete_env(:sdd_orchestrator, key)
        end
      end)
    end

    ParticipationDeliveryDouble.succeed()

    context = DeliveryFixtures.delivery_project_fixture()
    feature = DeliveryFixtures.feature_fixture(context.project, context.account)

    {:ok, _current} =
      SpecificationStore.create(
        context.workspace,
        context.project.id,
        SpecificationFixtures.specification_attrs(),
        actor_ref: "owner"
      )

    %{
      context: context,
      authority: context.workspace,
      project: context.project,
      feature: feature,
      owner: context.owner_actor,
      participant: context.participant_actor,
      owner_account: context.account
    }
  end

  describe "starting a ready feature [AC-15]" do
    setup ctx, do: %{ready: prepare(ctx)}

    test "creates the run, first attempt, activity, and start command together", %{
      authority: authority,
      project: project,
      owner: owner,
      ready: ready
    } do
      assert {:ok, results} =
               Start.start(authority, owner, %{project: project, feature: ready})

      assert %AgentRun{} = results.run
      assert %RunAttempt{} = results.attempt
      assert %ActivityEntry{} = results.activity
      assert %RunCommand{} = results.command

      assert results.feature.lifecycle_column == "in_development"
      assert results.run.state == "pending"
      assert results.attempt.attempt_number == 1
      assert results.attempt.continuation_reason == "initial"
      assert results.command.operation == "start"
      assert results.command.manifest_digest == results.attempt.manifest_digest
    end

    test "binds the run to the exact current revision and its own branch", %{
      authority: authority,
      project: project,
      owner: owner,
      ready: ready
    } do
      {:ok, current} =
        SpecificationStore.current_snapshot(authority, project.id)
        |> then(fn {:ok, %{specifications: [entry | _]}} ->
          SpecificationStore.get_current(authority, project.id, entry.id)
        end)

      {:ok, results} = Start.start(authority, owner, %{project: project, feature: ready})

      assert results.run.starting_revision_id == current.revision.id
      assert results.run.starting_revision_digest == current.revision.content_digest
      assert results.run.effective_revision_id == results.run.starting_revision_id
      assert results.run.branch == "sdd/run-#{results.run.id}"
      assert results.run.approved_slice == "slice-07"
    end

    test "records who started it, on which branch, against which revision", %{
      authority: authority,
      project: project,
      owner: owner,
      owner_account: owner_account,
      ready: ready
    } do
      {:ok, results} = Start.start(authority, owner, %{project: project, feature: ready})

      assert results.activity.type == "run_started"
      assert results.activity.actor_account_id == owner_account.id
      assert results.activity.payload["branch"] == results.run.branch
      assert results.activity.payload["revision_id"] == results.run.starting_revision_id
      assert results.activity.run_id == results.run.id
      assert results.activity.attempt_id == results.attempt.id
    end

    test "any current participant may start, not only the owner", %{
      authority: authority,
      project: project,
      participant: participant,
      ready: ready
    } do
      {:ok, _confirmed} =
        ProcessingDisclosure.confirm(
          project.id,
          participant,
          ProcessingDisclosure.describe().digest
        )

      assert {:ok, results} =
               Start.start(authority, participant, %{project: project, feature: ready})

      assert results.run.state == "pending"
    end

    test "the attempt's manifest digest is the digest of a real manifest", %{
      authority: authority,
      project: project,
      owner: owner,
      ready: ready
    } do
      {:ok, results} = Start.start(authority, owner, %{project: project, feature: ready})

      {:ok, manifest} =
        ExecutionManifest.new(%{
          "manifest_version" => ExecutionManifest.manifest_version(),
          "project_id" => project.id,
          "feature_id" => ready.id,
          "run_id" => results.run.id,
          "attempt_number" => 1,
          "approved_slice" => "slice-07",
          "starting_revision_id" => results.run.starting_revision_id,
          "starting_revision_digest" => results.run.starting_revision_digest,
          "effective_revision_id" => results.run.effective_revision_id,
          "effective_revision_digest" => results.run.effective_revision_digest,
          "repository_base_revision" => "a1b2c3d4e5f6a7b8",
          "target_branch" => results.run.branch,
          "required_checks" => [%{"name" => "mix test", "command" => "mix test"}],
          "agent_ref" => %{"provider" => "configured-agent"},
          "worker_ref" => %{"target" => "configured-worker"},
          "continuation" => %{"reason" => "initial", "prior_attempt_number" => nil}
        })

      assert ExecutionManifest.digest(manifest) == results.attempt.manifest_digest
    end
  end

  describe "nothing starts by itself [AC-14]" do
    test "becoming ready creates no run, attempt, or command", %{
      authority: authority,
      project: project,
      feature: feature,
      owner: owner
    } do
      _ready = prepare(%{authority: authority, project: project, feature: feature, owner: owner})

      assert Repo.aggregate(AgentRun, :count) == 0
      assert Repo.aggregate(RunAttempt, :count) == 0
      assert Repo.aggregate(RunCommand, :count) == 0
    end

    test "a feature that is not ready cannot be started", %{
      authority: authority,
      project: project,
      feature: feature,
      owner: owner
    } do
      ReadinessGuidanceDouble.script({:findings, [blocker()]})

      {:ok, _assessment} =
        Readiness.assess(authority, owner, %{project: project, feature: feature})

      {:ok, _confirmed} =
        ProcessingDisclosure.confirm(project.id, owner, ProcessingDisclosure.describe().digest)

      assert {:error, :not_ready} =
               Start.start(authority, owner, %{project: project, feature: feature})

      assert Repo.aggregate(AgentRun, :count) == 0
      assert Repo.get!(Feature, feature.id).lifecycle_column == "draft"
    end

    test "an unconfirmed processing boundary blocks the start", %{
      authority: authority,
      project: project,
      feature: feature,
      owner: owner
    } do
      ready = promote(%{authority: authority, project: project, feature: feature, owner: owner})

      assert {:error, :boundary_unconfirmed} =
               Start.start(authority, owner, %{project: project, feature: ready})

      assert Repo.aggregate(AgentRun, :count) == 0
    end

    test "a boundary that changed since confirmation blocks the start", %{
      authority: authority,
      project: project,
      feature: feature,
      owner: owner
    } do
      ready = prepare(%{authority: authority, project: project, feature: feature, owner: owner})

      Application.put_env(
        :sdd_orchestrator,
        :processing_boundary,
        Keyword.put(@boundary, :transfers, ["specifications"])
      )

      assert {:error, :boundary_unconfirmed} =
               Start.start(authority, owner, %{project: project, feature: ready})
    end

    test "a revision edited after readiness blocks the start", %{
      authority: authority,
      project: project,
      feature: feature,
      owner: owner
    } do
      ready = prepare(%{authority: authority, project: project, feature: feature, owner: owner})

      {:ok, %{specifications: [entry | _rest]}} =
        SpecificationStore.current_snapshot(authority, project.id)

      {:ok, current} = SpecificationStore.get_current(authority, project.id, entry.id)

      {:ok, _appended} =
        SpecificationStore.append_revision(
          authority,
          project.id,
          entry.id,
          current.revision.id,
          %{
            revision_id: Ecto.UUID.generate(),
            documents:
              SpecificationFixtures.documents(%{requirements: "# Requirements\\n\\nNew."}),
            actor_ref: "owner"
          }
        )

      assert {:error, :not_ready} =
               Start.start(authority, owner, %{project: project, feature: ready})

      assert Repo.aggregate(AgentRun, :count) == 0
    end
  end

  describe "duplicate start" do
    setup ctx, do: %{ready: prepare(ctx)}

    test "a second start while a run is live is rejected", %{
      authority: authority,
      project: project,
      owner: owner,
      ready: ready
    } do
      {:ok, results} = Start.start(authority, owner, %{project: project, feature: ready})

      assert {:error, :already_started} =
               Start.start(authority, owner, %{project: project, feature: results.feature})

      assert Repo.aggregate(AgentRun, :count) == 1
      assert Repo.aggregate(RunCommand, :count) == 1
    end

    test "starting again after cancellation creates a different run and branch", %{
      authority: authority,
      project: project,
      owner: owner,
      ready: ready
    } do
      {:ok, first} = Start.start(authority, owner, %{project: project, feature: ready})

      {:ok, canceled} =
        first.run
        |> AgentRun.transition_changeset("canceled", first.run.state_version)
        |> Repo.update()

      {:ok, back_to_ready} =
        first.feature
        |> Feature.transition_changeset("ready_for_development", first.feature.state_version)
        |> Repo.update()

      assert {:ok, second} =
               Start.start(authority, owner, %{project: project, feature: back_to_ready})

      refute second.run.id == canceled.id
      refute second.run.branch == canceled.branch
      assert Repo.aggregate(AgentRun, :count) == 2
    end
  end

  describe "authorization" do
    setup ctx, do: %{ready: prepare(ctx)}

    test "an outsider cannot start", %{authority: authority, project: project, ready: ready} do
      assert {:error, :unauthorized} =
               Start.start(authority, %{account_id: Ecto.UUID.generate()}, %{
                 project: project,
                 feature: ready
               })

      assert Repo.aggregate(AgentRun, :count) == 0
    end

    test "a departed participant cannot start", %{
      authority: authority,
      context: context,
      project: project,
      owner_account: owner_account,
      participant: participant,
      ready: ready
    } do
      {:ok, _confirmed} =
        ProcessingDisclosure.confirm(
          project.id,
          participant,
          ProcessingDisclosure.describe().digest
        )

      {:ok, _removed} =
        Revocations.remove(project, owner_account.id, context.identity.hosted_identity.id)

      assert {:error, :unauthorized} =
               Start.start(authority, participant, %{project: project, feature: ready})

      assert Repo.aggregate(AgentRun, :count) == 0
    end

    test "an unsupported authority fails closed", %{project: project, ready: ready} do
      assert {:error, _reason} =
               Start.start(%DeviceWorkspace{id: Ecto.UUID.generate()}, %{account_id: nil}, %{
                 project: project,
                 feature: ready
               })
    end
  end

  describe "availability" do
    test "is false until ready, confirmed, and in the right column", %{
      authority: authority,
      project: project,
      feature: feature,
      owner: owner
    } do
      refute Start.available?(authority, owner, %{project: project, feature: feature})

      ready = prepare(%{authority: authority, project: project, feature: feature, owner: owner})

      assert Start.available?(authority, owner, %{project: project, feature: ready})
    end

    test "is false for a participant who has not confirmed the boundary", %{
      authority: authority,
      project: project,
      feature: feature,
      owner: owner,
      participant: participant
    } do
      ready = prepare(%{authority: authority, project: project, feature: feature, owner: owner})

      refute Start.available?(authority, participant, %{project: project, feature: ready})
    end
  end

  # Assess with no blockers, promote to ready, and confirm the boundary — the
  # three things a person does before the start button is real.
  defp prepare(ctx) do
    ready = promote(ctx)

    {:ok, _confirmed} =
      ProcessingDisclosure.confirm(
        ctx.project.id,
        ctx.owner,
        ProcessingDisclosure.describe().digest
      )

    ready
  end

  defp promote(%{authority: authority, project: project, feature: feature, owner: owner}) do
    ReadinessGuidanceDouble.script({:findings, []})
    {:ok, _assessment} = Readiness.assess(authority, owner, %{project: project, feature: feature})

    {:ok, %{results: %{feature: ready}}} =
      Suggestions.promote(
        authority,
        owner,
        %{project: project, feature: feature},
        "ready:#{feature.id}"
      )

    ready
  end

  defp blocker do
    %{
      "id" => "missing-users",
      "category" => "missing",
      "blocking" => true,
      "summary" => "Nobody says who this is for.",
      "explanation" => "Name the people who will use this."
    }
  end
end
