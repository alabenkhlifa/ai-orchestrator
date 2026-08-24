defmodule SddOrchestrator.Delivery.LocalWorkerRuntimeProjectionTest do
  @moduledoc "Task 4 proof for the combined governed-run runtime projection."

  use SddOrchestrator.DataCase, async: true

  import SddOrchestrator.AIRuntimeFixtures
  import SddOrchestrator.DeliveryFixtures

  alias SddOrchestrator.AIRuntime.RuntimeProjections
  alias SddOrchestrator.Delivery.{LocalWorkerRunGovernance, LocalWorkerRuntimeProjection}
  alias SddOrchestrator.ParticipationFixtures

  describe "for_run/5" do
    test "an ungoverned run returns :ungoverned" do
      %{project: project, account: owner_account, owner_actor: owner_actor} =
        delivery_project_fixture()

      feature = feature_fixture(project, owner_account)

      %{run: run, attempt: attempt} =
        run_with_attempt_fixture(project, feature, %{initiator_account_id: owner_account.id})

      assert LocalWorkerRuntimeProjection.for_run(
               run,
               attempt,
               project.id,
               owner_account.id,
               owner_actor
             ) == {:ok, :ungoverned}
    end

    test "the run initiator sees the owner-exact projection with the live snapshot" do
      ctx = governed_context()

      assert {:ok, {:owner, projection}} =
               LocalWorkerRuntimeProjection.for_run(
                 ctx.run,
                 ctx.attempt,
                 ctx.project.id,
                 ctx.initiator_account.id,
                 ctx.initiator_actor
               )

      assert Enum.sort(Map.keys(projection)) ==
               Enum.sort([:snapshot | RuntimeProjections.owner_keys()])

      assert projection.session_id == ctx.session.session_id
      assert projection.consumer_ref == ctx.session.consumer_ref
      assert projection.model == "codex-test-model"
      assert projection.effort == "medium"
      refute projection.quota == %{state: :unknown}

      assert projection.snapshot.status == ctx.attempt.state
      assert projection.snapshot.elapsed_seconds >= 0
      assert projection.snapshot.tokens == :unknown
      assert projection.snapshot.cost == :unknown
    end

    test "the project owner, not being the initiator, sees only the safe participant projection" do
      ctx = governed_context()

      assert {:ok, {:participant, projection}} =
               LocalWorkerRuntimeProjection.for_run(
                 ctx.run,
                 ctx.attempt,
                 ctx.project.id,
                 ctx.owner_account.id,
                 ctx.owner_actor
               )

      assert Enum.sort(Map.keys(projection)) ==
               Enum.sort([:snapshot | RuntimeProjections.participant_keys()])

      refute Map.has_key?(projection, :consumer_ref)
      refute Map.has_key?(projection, :consumer)
      refute Map.has_key?(projection, :quota)
      refute Map.has_key?(projection, :spend)
      refute Map.has_key?(projection, :pinned_at)

      assert projection.model == "codex-test-model"
      assert projection.effort == "medium"
      assert projection.snapshot.status == ctx.attempt.state
      assert projection.snapshot.tokens == :unknown
      assert projection.snapshot.cost == :unknown
    end

    test "another current authorized participant, not the initiator, also sees only the safe projection" do
      ctx = governed_context()

      assert {:ok, {:participant, projection}} =
               LocalWorkerRuntimeProjection.for_run(
                 ctx.run,
                 ctx.attempt,
                 ctx.project.id,
                 ctx.other_participant_account.id,
                 ctx.other_participant_actor
               )

      assert Enum.sort(Map.keys(projection)) ==
               Enum.sort([:snapshot | RuntimeProjections.participant_keys()])
    end

    test "an actor with no legitimate access is refused" do
      ctx = governed_context()
      outsider = ParticipationFixtures.invited_identity_fixture()

      outsider_actor = %{
        account_id: outsider.account.id,
        hosted_identity_id: outsider.hosted_identity.id
      }

      assert LocalWorkerRuntimeProjection.for_run(
               ctx.run,
               ctx.attempt,
               ctx.project.id,
               outsider.account.id,
               outsider_actor
             ) == {:error, :unavailable}
    end
  end

  # The initiator is a project participant, never the project owner, so the
  # owner-exact/participant-safe split proves the fix directly rather than
  # coincidentally: the project owner must fall through to
  # `participant_projection/4` exactly like any other non-initiator.
  # The projection reads the quota through the live clock, and a quota snapshot
  # is deliberately refused once its short TTL has passed rather than read as
  # zero or unlimited. Anchoring this fixture to a frozen past instant therefore
  # made the owner-projection proof pass only in the few minutes after it was
  # written, and report an unknown quota forever after.
  defp live_now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp governed_context do
    %{
      project: project,
      account: owner_account,
      owner_actor: owner_actor,
      identity: identity,
      participant_actor: initiator_actor
    } = delivery_project_fixture()

    initiator_account = identity.account

    other_identity = ParticipationFixtures.invited_identity_fixture()
    ParticipationFixtures.participant_fixture(project, other_identity.hosted_identity)

    ParticipationFixtures.member_profile_fixture(project, other_identity.account, %{
      role: "participant",
      display_name: "Other Participant"
    })

    other_participant_actor = %{
      account_id: other_identity.account.id,
      hosted_identity_id: other_identity.hosted_identity.id
    }

    feature = feature_fixture(project, owner_account)

    %{run: run, attempt: attempt} =
      run_with_attempt_fixture(project, feature, %{initiator_account_id: initiator_account.id})

    session_context =
      runtime_observation_context_fixture(%{
        account: initiator_account,
        now: live_now(),
        consumer_ref: "local_worker_run:" <> run.id
      })

    {:ok, governance} =
      LocalWorkerRunGovernance.record(run.id, session_context.session.session_id)

    %{
      project: project,
      run: run,
      attempt: attempt,
      governance: governance,
      session: session_context.session,
      owner_account: owner_account,
      owner_actor: owner_actor,
      initiator_account: initiator_account,
      initiator_actor: initiator_actor,
      other_participant_account: other_identity.account,
      other_participant_actor: other_participant_actor
    }
  end
end
