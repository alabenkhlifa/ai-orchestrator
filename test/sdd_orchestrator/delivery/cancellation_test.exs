defmodule SddOrchestrator.Delivery.CancellationTest do
  @moduledoc """
  Proof for authorized cancellation and restart readiness (Task 26).

  Cancelling is the delivery action that throws work away, so these tests pin
  the narrow authority first: the run's initiator and the project owner may end
  it, any other current participant may not, and an initiator who has left the
  project loses the authority the owner keeps.

  They then pin what cancellation is. It stops the worker, it is terminal, and
  nothing about it is a pause: the run, its attempt, its activity, and its
  evidence stay as governed records, no resume exists, and picking the feature
  up again has to produce a different run on a different branch. Where the
  feature lands is decided by its requirements now, not by where it was when the
  run started.
  """
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Delivery.{
    ActivityEntry,
    AgentRun,
    Cancellation,
    DeliveryStore,
    Feature,
    ProcessingDisclosure,
    Readiness,
    ReadinessAssessment,
    Retry,
    RunAttempt,
    RunCommand,
    Start,
    Suggestions
  }

  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.Participation.Revocations
  alias SddOrchestrator.ParticipationDeliveryDouble
  alias SddOrchestrator.ParticipationFixtures
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

    # A third member is what makes "any other participant" a real case: without
    # one, everybody on the project is either the initiator or the owner.
    bystander = ParticipationFixtures.invited_identity_fixture()
    ParticipationFixtures.participant_fixture(context.project, bystander.hosted_identity)

    ParticipationFixtures.member_profile_fixture(context.project, bystander.account, %{
      role: "participant",
      display_name: ParticipationFixtures.unique_display_name("Bystander")
    })

    %{
      context: context,
      authority: context.workspace,
      project: context.project,
      feature: feature,
      owner: context.owner_actor,
      initiator: context.participant_actor,
      bystander: %{
        account_id: bystander.account.id,
        hosted_identity_id: bystander.hosted_identity.id
      },
      owner_account: context.account
    }
  end

  describe "who may cancel [AC-32]" do
    setup ctx, do: started(ctx)

    test "the participant who started the run may end it", %{
      authority: authority,
      project: project,
      feature: feature,
      initiator: initiator,
      run: run
    } do
      assert {:ok, results} =
               Cancellation.cancel(authority, initiator, %{project: project, feature: feature})

      assert results.run.id == run.id
      assert results.run.state == "canceled"
    end

    test "the project owner may end a run they did not start", %{
      authority: authority,
      project: project,
      feature: feature,
      owner: owner,
      owner_account: owner_account,
      run: run
    } do
      # The owner is deliberately not the initiator here, which is the whole
      # point of naming them separately.
      refute run.initiator_account_id == owner_account.id

      assert {:ok, results} =
               Cancellation.cancel(authority, owner, %{project: project, feature: feature})

      assert results.run.state == "canceled"
    end

    test "another current participant may not, and the run stays as it was", %{
      authority: authority,
      project: project,
      feature: feature,
      bystander: bystander,
      run: run
    } do
      assert {:error, :unauthorized} =
               Cancellation.cancel(authority, bystander, %{project: project, feature: feature})

      stored = Repo.get!(AgentRun, run.id)

      assert stored.state == "running"
      assert stored.state_version == run.state_version
      assert Repo.get!(Feature, feature.id).lifecycle_column == "in_development"

      # Only the start command exists: a refused cancellation must not reach the
      # worker in any form.
      assert cancel_commands() == 0

      # The screen must not offer what the action would refuse.
      assert {:ok, nil} =
               Cancellation.cancelable(authority, bystander, %{project: project, feature: feature})
    end

    test "an initiator who left the project loses the authority the owner keeps", %{
      authority: authority,
      context: context,
      project: project,
      feature: feature,
      initiator: initiator,
      owner: owner,
      owner_account: owner_account
    } do
      {:ok, _revoked} =
        Revocations.remove(project, owner_account.id, context.identity.hosted_identity.id)

      assert {:error, :unauthorized} =
               Cancellation.cancel(authority, initiator, %{project: project, feature: feature})

      assert {:error, :unauthorized} =
               Cancellation.cancelable(authority, initiator, %{project: project, feature: feature})

      # The run does not become uncancellable because the person who started it
      # is gone; that is exactly why the owner holds the same authority.
      assert {:ok, results} =
               Cancellation.cancel(authority, owner, %{project: project, feature: feature})

      assert results.run.state == "canceled"
    end
  end

  describe "what one cancellation commits [AC-33]" do
    setup ctx, do: started(ctx)

    test "ends the attempt and the run and queues one cancel command", %{
      authority: authority,
      project: project,
      feature: feature,
      initiator: initiator,
      attempt: attempt
    } do
      {:ok, results} =
        Cancellation.cancel(authority, initiator, %{project: project, feature: feature})

      assert results.attempt.id == attempt.id
      assert results.attempt.state == "canceled"
      refute RunAttempt.current?(results.attempt)

      assert results.run.state == "canceled"
      assert results.command.operation == "cancel"
      assert results.command.attempt_id == attempt.id
      assert results.command.state == "pending"

      # A control command carries no manifest: there is nothing to execute, only
      # something to stop.
      assert is_nil(results.command.manifest_digest)
      assert results.command.expected_state_version == results.run.state_version
      assert cancel_commands() == 1
    end

    test "writes the attempt, the run, and the feature exactly once each", %{
      authority: authority,
      project: project,
      feature: feature,
      initiator: initiator,
      run: run,
      attempt: attempt
    } do
      before = Repo.get!(Feature, feature.id)

      {:ok, results} =
        Cancellation.cancel(authority, initiator, %{project: project, feature: feature})

      # One version step per record is the proof: a second write inside the same
      # commit would either bump twice or be rejected as stale.
      assert results.attempt.state_version == attempt.state_version + 1
      assert results.run.state_version == run.state_version + 1
      assert results.feature.state_version == before.state_version + 1
    end

    test "records who ended it and on which branch", %{
      authority: authority,
      context: context,
      project: project,
      feature: feature,
      initiator: initiator,
      run: run
    } do
      {:ok, results} =
        Cancellation.cancel(authority, initiator, %{project: project, feature: feature})

      assert results.activity.type == "run_canceled"
      assert results.activity.actor_kind == "participant"
      assert results.activity.actor_account_id == context.identity.account.id
      assert results.activity.run_id == run.id
      assert results.activity.payload["branch"] == run.branch
      assert results.activity.payload["returned_to"] == "ready_for_development"
    end

    test "repeating the cancel is refused without a second command", %{
      authority: authority,
      project: project,
      feature: feature,
      initiator: initiator,
      owner: owner
    } do
      {:ok, _first} =
        Cancellation.cancel(authority, initiator, %{project: project, feature: feature})

      assert {:error, :already_canceled} =
               Cancellation.cancel(authority, initiator, %{project: project, feature: feature})

      # Not even the owner may cancel it twice: the run is terminal, not merely
      # out of this person's reach.
      assert {:error, :already_canceled} =
               Cancellation.cancel(authority, owner, %{project: project, feature: feature})

      assert cancel_commands() == 1
      assert entries("run_canceled") == 1
    end

    test "the worker's stop is acknowledged against the same command", %{
      authority: authority,
      project: project,
      feature: feature,
      initiator: initiator
    } do
      {:ok, results} =
        Cancellation.cancel(authority, initiator, %{project: project, feature: feature})

      assert {:ok, acknowledged} =
               DeliveryStore.acknowledge_command(authority, project.id, results.command.id, %{
                 "stopped" => true
               })

      assert acknowledged.id == results.command.id
      assert acknowledged.state == "acknowledged"
      assert acknowledged.result == %{"stopped" => true}

      # The acknowledgement is the worker reporting, never a second decision: the
      # run was already terminal before the worker answered.
      assert Repo.get!(AgentRun, results.run.id).state == "canceled"
    end

    test "history, activity, and evidence stay as governed records", %{
      authority: authority,
      project: project,
      feature: feature,
      initiator: initiator,
      run: run,
      attempt: attempt
    } do
      {:ok, _results} =
        Cancellation.cancel(authority, initiator, %{project: project, feature: feature})

      kept = Repo.get!(AgentRun, run.id)

      assert kept.branch == run.branch
      assert kept.starting_revision_id == run.starting_revision_id
      assert kept.starting_revision_digest == run.starting_revision_digest

      # The attempt keeps the manifest its work was done against, which is what
      # makes the recorded evidence readable later.
      assert Repo.get!(RunAttempt, attempt.id).manifest_digest == attempt.manifest_digest

      assert entries("run_started") == 1
      assert entries("run_canceled") == 1
    end
  end

  describe "where the feature goes next [AC-33]" do
    setup ctx, do: started(ctx)

    test "returns to Ready for development when the current revision still is", %{
      authority: authority,
      project: project,
      feature: feature,
      initiator: initiator
    } do
      {:ok, results} =
        Cancellation.cancel(authority, initiator, %{project: project, feature: feature})

      assert results.feature.lifecycle_column == "ready_for_development"

      # The status the run left behind goes with it.
      assert results.feature.status == "none"
      assert Repo.get!(Feature, feature.id).lifecycle_column == "ready_for_development"
    end

    test "falls back to Draft when the current revision no longer is", %{
      authority: authority,
      project: project,
      feature: feature,
      initiator: initiator,
      owner: owner
    } do
      # The requirements changed while the run was in flight, so offering a
      # start again would offer one nothing could honour.
      ReadinessGuidanceDouble.script({:findings, [ReadinessGuidanceDouble.finding()]})

      {:ok, _assessment} =
        Readiness.assess(authority, owner, %{project: project, feature: feature})

      {:ok, results} =
        Cancellation.cancel(authority, initiator, %{project: project, feature: feature})

      assert results.feature.lifecycle_column == "draft"
      assert results.activity.payload["returned_to"] == "draft"
      refute Start.available?(authority, initiator, %{project: project, feature: results.feature})
    end

    test "an assessment that no longer matches the revision in play is not readiness", %{
      authority: authority,
      project: project,
      feature: feature,
      initiator: initiator
    } do
      # A verdict bound to a revision nobody is working from proves nothing, so
      # the feature goes back to Draft rather than inheriting a stale yes.
      ReadinessAssessment
      |> Repo.get_by!(feature_id: feature.id)
      |> Ecto.Changeset.change(revision_digest: String.duplicate("f", 64))
      |> Repo.update!()

      {:ok, results} =
        Cancellation.cancel(authority, initiator, %{project: project, feature: feature})

      assert results.feature.lifecycle_column == "draft"
    end
  end

  describe "after cancellation [AC-33]" do
    setup ctx, do: started(ctx)

    test "there is no resume: nothing leaves the canceled state", %{
      authority: authority,
      project: project,
      feature: feature,
      initiator: initiator
    } do
      {:ok, results} =
        Cancellation.cancel(authority, initiator, %{project: project, feature: feature})

      assert AgentRun.transitions()["canceled"] == []
      assert AgentRun.terminal?(results.run)

      # Not through the store either, whoever asks and however it is phrased.
      assert {:error, :run, _stale} =
               DeliveryStore.commit(authority, project.id, [
                 {:run, {:transition_run, results.run, "running", []}}
               ])

      # And not through the recovery path a stopped run would otherwise offer.
      assert {:error, :no_failed_run} =
               Retry.retry_now(authority, initiator, %{project: project, feature: feature})

      assert {:ok, nil} =
               Retry.pending(authority, initiator, %{project: project, feature: feature})
    end

    test "a later start creates a new run on a new branch", %{
      authority: authority,
      project: project,
      feature: feature,
      initiator: initiator,
      run: run
    } do
      {:ok, canceled} =
        Cancellation.cancel(authority, initiator, %{project: project, feature: feature})

      assert Start.available?(authority, initiator, %{project: project, feature: canceled.feature})

      assert {:ok, restarted} =
               Start.start(authority, initiator, %{project: project, feature: canceled.feature})

      refute restarted.run.id == run.id
      refute restarted.run.branch == run.branch
      assert restarted.attempt.attempt_number == 1
      assert restarted.attempt.continuation_reason == "initial"
      assert restarted.command.operation == "start"

      # Two runs, both kept: the canceled one is history, not a slot that was
      # reused.
      assert Repo.aggregate(AgentRun, :count) == 2
      assert Repo.get!(AgentRun, run.id).state == "canceled"
      assert Repo.get!(AgentRun, restarted.run.id).state == "pending"
      assert Repo.get!(Feature, feature.id).lifecycle_column == "in_development"
    end

    test "the new run does not inherit the canceled run's attempt or branch", %{
      authority: authority,
      project: project,
      feature: feature,
      initiator: initiator,
      run: run,
      attempt: attempt
    } do
      {:ok, canceled} =
        Cancellation.cancel(authority, initiator, %{project: project, feature: feature})

      {:ok, restarted} =
        Start.start(authority, initiator, %{project: project, feature: canceled.feature})

      assert restarted.attempt.run_id == restarted.run.id
      refute restarted.attempt.id == attempt.id
      refute restarted.attempt.manifest_digest == attempt.manifest_digest
      assert restarted.run.branch == "sdd/run-#{restarted.run.id}"

      # The old branch is still spoken for, which is what keeps the recorded
      # work findable.
      assert Repo.get!(AgentRun, run.id).branch == run.branch
    end
  end

  describe "refusals" do
    test "a feature with no run has nothing to cancel", %{
      authority: authority,
      project: project,
      feature: feature,
      owner: owner
    } do
      assert {:error, :no_active_run} =
               Cancellation.cancel(authority, owner, %{project: project, feature: feature})

      assert {:ok, nil} =
               Cancellation.cancelable(authority, owner, %{project: project, feature: feature})
    end

    test "someone who is not on the project learns nothing", %{
      authority: authority,
      project: project,
      feature: feature
    } do
      stranger = %{account_id: Ecto.UUID.generate(), hosted_identity_id: nil}

      assert {:error, :unauthorized} =
               Cancellation.cancel(authority, stranger, %{project: project, feature: feature})

      assert {:error, :unauthorized} =
               Cancellation.cancelable(authority, stranger, %{project: project, feature: feature})
    end

    test "a stopped run is still cancelable", %{
      authority: authority,
      project: project,
      feature: feature,
      owner: owner
    } do
      assert "failed" in Cancellation.cancelable_states()
      assert "blocked" in Cancellation.cancelable_states()
      refute "completed" in Cancellation.cancelable_states()
      refute "canceled" in Cancellation.cancelable_states()

      assert {:error, :no_active_run} =
               Cancellation.cancel(authority, owner, %{project: project, feature: feature})
    end
  end

  # One real run, started through the product rather than inserted: the
  # cancellation contract is about what happens to a run the start path
  # actually produced.
  defp started(%{authority: authority, project: project, feature: feature} = ctx) do
    ReadinessGuidanceDouble.script({:findings, []})

    {:ok, _assessment} =
      Readiness.assess(authority, ctx.owner, %{project: project, feature: feature})

    {:ok, %{results: %{feature: ready}}} =
      Suggestions.promote(
        authority,
        ctx.owner,
        %{project: project, feature: feature},
        "ready:#{feature.id}"
      )

    digest = ProcessingDisclosure.describe().digest
    {:ok, _owner_confirmed} = ProcessingDisclosure.confirm(project.id, ctx.owner, digest)
    {:ok, _confirmed} = ProcessingDisclosure.confirm(project.id, ctx.initiator, digest)

    {:ok, results} = Start.start(authority, ctx.initiator, %{project: project, feature: ready})

    {:ok, dispatched} =
      results.attempt
      |> RunAttempt.transition_changeset("dispatched", results.attempt.state_version)
      |> Repo.update()

    {:ok, running} =
      results.run
      |> AgentRun.transition_changeset("running", results.run.state_version)
      |> Repo.update()

    Map.merge(ctx, %{
      run: running,
      attempt: dispatched,
      feature: Repo.get!(Feature, results.feature.id)
    })
  end

  defp cancel_commands do
    RunCommand |> where([c], c.operation == "cancel") |> Repo.aggregate(:count)
  end

  defp entries(type) do
    ActivityEntry |> where([e], e.type == ^type) |> Repo.aggregate(:count)
  end
end
