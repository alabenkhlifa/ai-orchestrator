defmodule SddOrchestrator.Delivery.RunTransitionsTest do
  @moduledoc """
  Proof for authoritative run-state transactions (Task 3).

  The invariant is that a feature's column, its run's state, its history, and
  the worker's next instruction can never disagree, because they are one
  transaction. The second invariant is that a caller who is unsure whether its
  request committed can safely repeat it.

  Every test runs against both storage authorities, since the guarantee is
  worth nothing if it only holds for hosted projects.
  """
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Accounts.DeviceWorkspace

  alias SddOrchestrator.Delivery.{
    ActivityEntry,
    DeliveryStore,
    Feature,
    RunCommand,
    RunTransitions
  }

  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.DeviceStore.Local
  alias SddOrchestrator.Repo

  setup context do
    hosted = DeliveryFixtures.delivery_project_fixture()
    feature = DeliveryFixtures.feature_fixture(hosted.project, hosted.account)

    path =
      Path.join(System.tmp_dir!(), "run-transitions-#{System.unique_integer([:positive])}.dets")

    start_supervised!({Local, path: path})
    on_exit(fn -> File.rm_rf(path) end)

    {:ok, device_workspace} = Devices.establish_workspace()

    authority =
      case context[:authority] do
        :device ->
          # A device-authoritative project's feature lives in the device store,
          # so the world each authority operates on has to be its own.
          {:ok, _written} =
            Devices.commit_delivery(hosted.project.id, [
              {:put, :feature, feature.id, Feature.to_value(feature), nil}
            ])

          %DeviceWorkspace{id: device_workspace.id}

        _hosted ->
          hosted.workspace
      end

    %{authority: authority, project: hosted.project, feature: feature, account: hosted.account}
  end

  for authority <- [:hosted, :device] do
    describe "#{authority} authority" do
      @describetag authority: authority

      test "moves the feature, records the history, and enqueues the command together", %{
        authority: authority,
        project: project,
        feature: feature
      } do
        run = seed_run(authority, project, feature)
        feature = ready_feature(authority, project, feature)

        assert {:ok, %{applied?: true, results: results}} =
                 RunTransitions.apply(authority, %{
                   operation_key: "start:#{run.id}",
                   project_id: project.id,
                   feature: feature,
                   run: run,
                   feature_column: "in_development",
                   run_state: "running",
                   activity: activity(project, feature, "run_started"),
                   command: command(project, run, "cancel")
                 })

        assert results.feature.lifecycle_column == "in_development"
        assert results.run.state == "running"
        assert results.activity.type == "run_started"
        assert results.command.operation == "cancel"
      end

      test "leaves nothing behind when the feature transition is illegal", %{
        authority: authority,
        project: project,
        feature: feature
      } do
        run = seed_run(authority, project, feature)

        assert {:error, _reason} =
                 RunTransitions.apply(authority, %{
                   operation_key: "illegal:#{run.id}",
                   project_id: project.id,
                   feature: feature,
                   run: run,
                   # `Draft` cannot reach `Done` directly.
                   feature_column: "done",
                   run_state: "running",
                   activity: activity(project, feature, "run_started"),
                   command: command(project, run, "cancel")
                 })

        assert DeliveryStore.list_activity(authority, project.id, feature.id) == []
        assert reload_feature(authority, project, feature).lifecycle_column == "draft"
      end

      test "leaves nothing behind when the run transition is illegal", %{
        authority: authority,
        project: project,
        feature: feature
      } do
        run = seed_run(authority, project, feature)
        feature = ready_feature(authority, project, feature)

        assert {:error, _reason} =
                 RunTransitions.apply(authority, %{
                   operation_key: "illegal-run:#{run.id}",
                   project_id: project.id,
                   feature: feature,
                   run: run,
                   feature_column: "in_development",
                   # `pending` cannot reach `completed` directly.
                   run_state: "completed",
                   activity: activity(project, feature, "run_started")
                 })

        assert length(DeliveryStore.list_activity(authority, project.id, feature.id)) == 1

        assert reload_feature(authority, project, feature).lifecycle_column ==
                 "ready_for_development"
      end

      test "rejects a request built from a superseded feature", %{
        authority: authority,
        project: project,
        feature: feature
      } do
        run = seed_run(authority, project, feature)

        {:ok, _first} =
          RunTransitions.apply(authority, %{
            operation_key: "first:#{run.id}",
            project_id: project.id,
            feature: feature,
            feature_column: "ready_for_development",
            activity: activity(project, feature, "readiness_evaluated")
          })

        # `feature` still carries the pre-transition state version.
        assert {:error, :stale_state} =
                 RunTransitions.apply(authority, %{
                   operation_key: "second:#{run.id}",
                   project_id: project.id,
                   feature: feature,
                   feature_column: "ready_for_development",
                   activity: activity(project, feature, "readiness_evaluated")
                 })
      end

      test "a repeated operation key returns the earlier effect without applying twice", %{
        authority: authority,
        project: project,
        feature: feature
      } do
        run = seed_run(authority, project, feature)
        feature = ready_feature(authority, project, feature)

        request = %{
          operation_key: "retry-safe:#{run.id}",
          project_id: project.id,
          feature: feature,
          run: run,
          feature_column: "in_development",
          run_state: "running",
          activity: activity(project, feature, "run_started"),
          command: command(project, run, "cancel")
        }

        assert {:ok, %{applied?: true, results: first}} = RunTransitions.apply(authority, request)

        assert {:ok, %{applied?: false, results: second}} =
                 RunTransitions.apply(authority, request)

        assert second.activity.id == first.activity.id

        # One transition, one history entry, one command — not two of each. The
        # readiness step from setup is the only other entry.
        entries = DeliveryStore.list_activity(authority, project.id, feature.id)

        assert Enum.count(entries, &(&1.payload["operation_key"] == request.operation_key)) == 1
        assert length(entries) == 2
        assert reload_feature(authority, project, feature).lifecycle_column == "in_development"
      end

      test "reports whether an operation key was already applied", %{
        authority: authority,
        project: project,
        feature: feature
      } do
        refute RunTransitions.applied?(authority, project.id, feature.id, "not-yet")

        {:ok, _applied} =
          RunTransitions.apply(authority, %{
            operation_key: "already",
            project_id: project.id,
            feature: feature,
            feature_column: "ready_for_development",
            activity: activity(project, feature, "readiness_evaluated")
          })

        assert RunTransitions.applied?(authority, project.id, feature.id, "already")
      end

      test "distinguishes two different operation keys on one feature", %{
        authority: authority,
        project: project,
        feature: feature
      } do
        {:ok, %{results: %{feature: ready}}} =
          RunTransitions.apply(authority, %{
            operation_key: "ready",
            project_id: project.id,
            feature: feature,
            feature_column: "ready_for_development",
            activity: activity(project, feature, "readiness_evaluated")
          })

        assert {:ok, %{applied?: true}} =
                 RunTransitions.apply(authority, %{
                   operation_key: "back-to-draft",
                   project_id: project.id,
                   feature: ready,
                   feature_column: "draft",
                   activity: activity(project, feature, "readiness_evaluated")
                 })

        assert length(DeliveryStore.list_activity(authority, project.id, feature.id)) == 2
      end

      test "records a visible status without moving the feature out of its column", %{
        authority: authority,
        project: project,
        feature: feature
      } do
        run = seed_run(authority, project, feature)
        ready = ready_feature(authority, project, feature)

        {:ok, %{results: %{feature: developing}}} =
          RunTransitions.apply(authority, %{
            operation_key: "start:#{run.id}",
            project_id: project.id,
            feature: ready,
            feature_column: "in_development",
            activity: activity(project, feature, "run_started")
          })

        assert {:ok, %{results: %{feature: blocked}}} =
                 RunTransitions.apply(authority, %{
                   operation_key: "blocked:#{run.id}",
                   project_id: project.id,
                   feature: developing,
                   feature_status: "blocked",
                   activity: activity(project, feature, "question_asked")
                 })

        assert blocked.status == "blocked"
        assert blocked.lifecycle_column == "in_development"
      end

      test "applies a transition with no command at all", %{
        authority: authority,
        project: project,
        feature: feature
      } do
        assert {:ok, %{applied?: true, results: results}} =
                 RunTransitions.apply(authority, %{
                   operation_key: "no-command",
                   project_id: project.id,
                   feature: feature,
                   feature_column: "ready_for_development",
                   activity: activity(project, feature, "readiness_evaluated")
                 })

        refute Map.has_key?(results, :command)
        assert results.feature.lifecycle_column == "ready_for_development"
      end

      test "rejects a request with no operation key", %{
        authority: authority,
        project: project,
        feature: feature
      } do
        assert {:error, :invalid_request} =
                 RunTransitions.apply(authority, %{
                   project_id: project.id,
                   feature: feature,
                   activity: activity(project, feature, "progress")
                 })
      end
    end
  end

  describe "device authority creates no hosted copy" do
    @describetag authority: :device

    test "a full device transition leaves the hosted tables untouched", %{
      authority: authority,
      project: project,
      feature: feature
    } do
      run = seed_run(authority, project, feature)
      ready = ready_feature(authority, project, feature)
      before = {Repo.aggregate(ActivityEntry, :count), Repo.aggregate(RunCommand, :count)}

      {:ok, %{applied?: true}} =
        RunTransitions.apply(authority, %{
          operation_key: "device:#{run.id}",
          project_id: project.id,
          feature: ready,
          run: run,
          feature_column: "in_development",
          run_state: "running",
          activity: activity(project, feature, "run_started"),
          command: command(project, run, "cancel")
        })

      assert {Repo.aggregate(ActivityEntry, :count), Repo.aggregate(RunCommand, :count)} == before

      # The hosted feature row is untouched too: the device holds its own copy.
      assert Repo.get!(Feature, feature.id).lifecycle_column == "draft"
    end
  end

  defp seed_run(authority, project, feature) do
    unique = System.unique_integer([:positive])
    digest = DeliveryFixtures.digest("rev-#{unique}")

    {:ok, %{run: run}} =
      DeliveryStore.commit(authority, project.id, [
        {:run,
         {:insert_run,
          %{
            project_id: project.id,
            feature_id: feature.id,
            starting_revision_id: "rev-#{unique}",
            starting_revision_digest: digest,
            approved_slice: "slice-07",
            branch: "sdd/feature-#{unique}"
          }}}
      ])

    run
  end

  # A feature reaches `In development` only through `Ready for development`;
  # the transition table is what makes the board's gates real.
  defp ready_feature(authority, project, feature) do
    {:ok, %{results: %{feature: ready}}} =
      RunTransitions.apply(authority, %{
        operation_key: "ready:#{feature.id}",
        project_id: project.id,
        feature: feature,
        feature_column: "ready_for_development",
        activity: activity(project, feature, "readiness_evaluated")
      })

    ready
  end

  defp activity(project, feature, type) do
    %{
      project_id: project.id,
      feature_id: feature.id,
      actor_kind: "system",
      type: type,
      payload: %{}
    }
  end

  defp command(project, run, operation) do
    %{
      id: Ecto.UUID.generate(),
      project_id: project.id,
      run_id: run.id,
      operation: operation,
      expected_state_version: run.state_version
    }
  end

  # The device authority keeps its own feature copy, so a reload has to ask the
  # same store the transition wrote to.
  defp reload_feature(%DeviceWorkspace{}, project, feature) do
    case Devices.get_delivery(project.id, :feature, feature.id) do
      {:ok, value} ->
        {:ok, stored} = Feature.from_value(value)
        stored

      {:error, :not_found} ->
        Repo.get!(Feature, feature.id)
    end
  end

  defp reload_feature(_hosted, _project, feature), do: Repo.get!(Feature, feature.id)
end
