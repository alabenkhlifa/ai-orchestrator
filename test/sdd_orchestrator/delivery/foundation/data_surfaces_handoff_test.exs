defmodule SddOrchestrator.Delivery.Foundation.DataSurfacesHandoffTest do
  @moduledoc """
  Handoff proof for `capability:guided-delivery-data-surfaces` (Task 54).

  The continuation slices govern the delivery records — inventory them, retain
  them, delete them — through this one store contract rather than through the
  hosted database directly. What a child may rely on is pinned here: the
  operation vocabulary is stable, hosted and device authorities answer one
  contract, an authority the store does not recognize fails closed, a stale
  write is refused, and every read is scoped to one project. Nothing here adds
  behavior; a failure means the published contract moved under its consumers.
  """
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Accounts.DeviceWorkspace
  alias SddOrchestrator.Delivery.{AgentRun, DeliveryStore, Feature}
  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.DeviceStore.Local

  setup do
    context = DeliveryFixtures.delivery_project_fixture()
    feature = DeliveryFixtures.feature_fixture(context.project, context.account)

    %{
      authority: context.workspace,
      project: context.project,
      owner: context.account,
      participant: context.identity,
      feature: feature
    }
  end

  describe "the published store contract" do
    test "the operation vocabulary is exactly what the foundation recorded" do
      # A child's processing inventory names these operations. A new or renamed
      # operation is a contract change its consumers have to hear about, so the
      # list is asserted whole rather than probed.
      assert Enum.sort(DeliveryStore.operations()) ==
               Enum.sort(~w(
                 insert_run transition_run set_effective_revision advance_attempt_number
                 resume_run insert_attempt transition_attempt claim_lease observe_sequence
                 transition_feature set_feature_status clear_assignment
                 insert_blocking_question resolve_question insert_evidence supersede_evidence
                 insert_preview_deployment observe_preview_deployment
                 supersede_preview_deployment record_preview_cleanup insert_review_decision
                 append_activity enqueue_command
               )a)
    end

    test "both real authorities are supported and an unknown one fails closed", ctx do
      assert DeliveryStore.supported?(ctx.authority)
      assert DeliveryStore.supported?(%DeviceWorkspace{id: Ecto.UUID.generate()})
      refute DeliveryStore.supported?(:not_an_authority)

      # A consumer that must not treat "could not ask" as "nothing to do" asks
      # `supported?/1` first; every read then answers an unusable authority with
      # the empty result it would give a project that genuinely has nothing.
      assert {:error, :authority, :unsupported_authority} =
               DeliveryStore.commit(:not_an_authority, ctx.project.id, [])

      assert DeliveryStore.fetch_run(:not_an_authority, ctx.project.id, ctx.feature.id) == :error
      assert DeliveryStore.current_attempt(:not_an_authority, ctx.project.id, "x") == :error
      assert DeliveryStore.latest_attempt(:not_an_authority, ctx.project.id, "x") == :error
      assert DeliveryStore.open_question(:not_an_authority, ctx.project.id, "x") == :error
      assert DeliveryStore.list_features(:not_an_authority, ctx.project.id) == []
      assert DeliveryStore.list_evidence(:not_an_authority, ctx.project.id) == []
      assert DeliveryStore.list_preview_deployments(:not_an_authority, ctx.project.id) == []
      assert DeliveryStore.list_review_decisions(:not_an_authority, ctx.project.id) == []
      assert DeliveryStore.list_activity(:not_an_authority, ctx.project.id, "x") == []
      assert DeliveryStore.claim_commands(:not_an_authority, ctx.project.id, "wrk") == []

      assert DeliveryStore.acknowledge_command(:not_an_authority, ctx.project.id, "x") ==
               {:error, :not_found}
    end
  end

  describe "hosted data surfaces" do
    test "one commit writes run, attempt, and activity atomically and each reads back", ctx do
      unique = System.unique_integer([:positive])
      digest = DeliveryFixtures.digest("rev-#{unique}")

      {:ok, %{run: run, attempt: attempt, activity: entry}} =
        DeliveryStore.commit(ctx.authority, ctx.project.id, [
          {:run,
           {:insert_run,
            %{
              project_id: ctx.project.id,
              feature_id: ctx.feature.id,
              initiator_account_id: ctx.owner.id,
              starting_revision_id: "rev-#{unique}",
              starting_revision_digest: digest,
              approved_slice: "slice-07",
              branch: "sdd/handoff-#{unique}"
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
            }}},
          {:activity,
           {:append_activity,
            %{
              project_id: ctx.project.id,
              feature_id: ctx.feature.id,
              run_id: {:ref, :run, :id},
              attempt_id: {:ref, :attempt, :id},
              actor_kind: "system",
              type: "progress",
              payload: %{"step" => "handoff"}
            }}}
        ])

      assert {:ok, fetched_run} = DeliveryStore.fetch_run(ctx.authority, ctx.project.id, run.id)
      assert fetched_run.id == run.id

      assert {:ok, fetched_feature} =
               DeliveryStore.fetch_feature(ctx.authority, ctx.project.id, ctx.feature.id)

      assert fetched_feature.id == ctx.feature.id

      assert {:ok, current} = DeliveryStore.current_attempt(ctx.authority, ctx.project.id, run.id)
      assert current.id == attempt.id
      assert {:ok, latest} = DeliveryStore.latest_attempt(ctx.authority, ctx.project.id, run.id)
      assert latest.id == attempt.id

      activity_ids =
        ctx.authority
        |> DeliveryStore.list_activity(ctx.project.id, ctx.feature.id)
        |> Enum.map(& &1.id)

      assert entry.id in activity_ids
    end

    test "a held-assignment read finds exactly what a departure has to clear", ctx do
      held =
        DeliveryFixtures.feature_fixture(ctx.project, ctx.owner, %{
          assigned_account_id: ctx.participant.account.id
        })

      _unassigned = DeliveryFixtures.feature_fixture(ctx.project, ctx.owner)

      assert [%Feature{id: held_id}] =
               DeliveryStore.list_features(ctx.authority, ctx.project.id,
                 assigned_account_id: ctx.participant.account.id
               )

      assert held_id == held.id
    end

    test "a superseded expected state is refused rather than applied", ctx do
      run = DeliveryFixtures.run_fixture(ctx.project, ctx.feature)

      {:ok, %{run: _running}} =
        DeliveryStore.commit(ctx.authority, ctx.project.id, [
          {:run, {:transition_run, run, "running", []}}
        ])

      # The same stale struct again: whichever child replays a write must see a
      # refusal, never a second application.
      assert {:error, _step, :stale_state} =
               DeliveryStore.commit(ctx.authority, ctx.project.id, [
                 {:run, {:transition_run, run, "running", []}}
               ])
    end

    test "every read is scoped to the one project it was asked about", ctx do
      other = DeliveryFixtures.delivery_project_fixture()
      run = DeliveryFixtures.run_fixture(ctx.project, ctx.feature)

      assert DeliveryStore.fetch_run(ctx.authority, other.project.id, run.id) == :error

      assert DeliveryStore.fetch_feature(ctx.authority, other.project.id, ctx.feature.id) ==
               :error

      listed = DeliveryStore.list_features(ctx.authority, other.project.id)
      refute ctx.feature.id in Enum.map(listed, & &1.id)
    end
  end

  describe "device data surfaces" do
    setup ctx do
      path =
        Path.join(
          System.tmp_dir!(),
          "data-surfaces-handoff-#{System.unique_integer([:positive])}.dets"
        )

      start_supervised!({Local, path: path})
      on_exit(fn -> File.rm_rf(path) end)

      {:ok, workspace} = Devices.establish_workspace()

      Map.put(ctx, :device, %DeviceWorkspace{id: workspace.id})
    end

    test "the device authority answers the same contract without a hosted copy", ctx do
      {:ok, _written} =
        Devices.commit_delivery(ctx.project.id, [
          {:put, :feature, ctx.feature.id, Feature.to_value(ctx.feature), nil}
        ])

      unique = System.unique_integer([:positive])

      {:ok, %{run: run}} =
        DeliveryStore.commit(ctx.device, ctx.project.id, [
          {:run,
           {:insert_run,
            %{
              project_id: ctx.project.id,
              feature_id: ctx.feature.id,
              starting_revision_id: "rev-#{unique}",
              starting_revision_digest: DeliveryFixtures.digest("rev-#{unique}"),
              approved_slice: "slice-07",
              branch: "sdd/device-handoff-#{unique}"
            }}}
        ])

      assert {:ok, fetched} = DeliveryStore.fetch_run(ctx.device, ctx.project.id, run.id)
      assert fetched.id == run.id
      assert fetched.branch == run.branch

      assert {:ok, feature} =
               DeliveryStore.fetch_feature(ctx.device, ctx.project.id, ctx.feature.id)

      assert feature.id == ctx.feature.id

      # The whole point of the two-adapter contract: the device project's
      # delivery state never became a hosted row.
      refute Repo.get(AgentRun, run.id)
    end
  end
end
