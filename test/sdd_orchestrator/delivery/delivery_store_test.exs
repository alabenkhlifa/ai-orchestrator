defmodule SddOrchestrator.Delivery.DeliveryStoreTest do
  @moduledoc """
  Parity proof for the two delivery-store adapters (Task 18).

  `specs/05` forbids keeping a device-authoritative project's data in the hosted
  database, so hosted and device delivery cannot be one implementation with a
  flag. Every behavioural test here is written once and run against both
  authorities, because the only thing that makes two implementations safe is
  proving they answer the same way.

  The last describe block is the one that cannot be shared: it proves the device
  adapter writes nothing into the hosted database at all.
  """
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Accounts.DeviceWorkspace
  alias SddOrchestrator.Delivery.{ActivityEntry, AgentRun, DeliveryStore, RunAttempt, RunCommand}
  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.DeviceStore.Local
  alias SddOrchestrator.Repo

  setup context do
    hosted = DeliveryFixtures.delivery_project_fixture()
    feature = DeliveryFixtures.feature_fixture(hosted.project, hosted.account)

    path =
      Path.join(
        System.tmp_dir!(),
        "delivery-store-#{System.unique_integer([:positive])}.dets"
      )

    start_supervised!({Local, path: path})
    on_exit(fn -> File.rm_rf(path) end)

    {:ok, device_workspace} = Devices.establish_workspace()

    authority =
      case context[:authority] do
        :device -> %DeviceWorkspace{id: device_workspace.id}
        _hosted -> hosted.workspace
      end

    %{
      authority: authority,
      hosted: hosted,
      project: hosted.project,
      feature: feature,
      account: hosted.account
    }
  end

  # Every behaviour below runs twice: once against PostgreSQL and once against
  # the worker-owned device store.
  for authority <- [:hosted, :device] do
    describe "#{authority} adapter" do
      @describetag authority: authority

      test "commits a run, its first attempt, activity, and start command atomically", %{
        authority: authority,
        project: project,
        feature: feature
      } do
        assert {:ok, results} =
                 DeliveryStore.commit(authority, project.id, start_steps(project, feature))

        assert %AgentRun{} = results.run
        assert %RunAttempt{} = results.attempt
        assert %ActivityEntry{} = results.activity
        assert %RunCommand{} = results.command

        assert results.run.state == "pending"
        assert results.attempt.attempt_number == 1
        assert results.activity.type == "run_started"
        assert results.command.operation == "start"
      end

      test "resolves a reference to a record created earlier in the same commit", %{
        authority: authority,
        project: project,
        feature: feature
      } do
        {:ok, results} =
          DeliveryStore.commit(authority, project.id, start_steps(project, feature))

        assert results.attempt.run_id == results.run.id
        assert results.activity.run_id == results.run.id
        assert results.activity.attempt_id == results.attempt.id
        assert results.command.run_id == results.run.id
        assert results.command.manifest_digest == results.attempt.manifest_digest
      end

      test "applies nothing when one step is invalid", %{
        authority: authority,
        project: project,
        feature: feature
      } do
        steps =
          start_steps(project, feature) ++
            [{:bad, {:append_activity, %{project_id: project.id, actor_kind: "nope"}}}]

        assert {:error, :bad, _reason} = DeliveryStore.commit(authority, project.id, steps)

        assert DeliveryStore.list_activity(authority, project.id, feature.id) == []
      end

      test "reads back the run and its one current attempt", %{
        authority: authority,
        project: project,
        feature: feature
      } do
        {:ok, results} =
          DeliveryStore.commit(authority, project.id, start_steps(project, feature))

        assert {:ok, run} = DeliveryStore.fetch_run(authority, project.id, results.run.id)
        assert run.branch == results.run.branch

        assert {:ok, attempt} =
                 DeliveryStore.current_attempt(authority, project.id, results.run.id)

        assert attempt.id == results.attempt.id
      end

      test "reports no run and no attempt for identifiers it does not hold", %{
        authority: authority,
        project: project
      } do
        assert :error = DeliveryStore.fetch_run(authority, project.id, Ecto.UUID.generate())
        assert :error = DeliveryStore.current_attempt(authority, project.id, Ecto.UUID.generate())
      end

      test "enforces the expected state version on a transition", %{
        authority: authority,
        project: project,
        feature: feature
      } do
        {:ok, %{run: run}} =
          DeliveryStore.commit(authority, project.id, start_steps(project, feature))

        assert {:ok, %{moved: moved}} =
                 DeliveryStore.commit(authority, project.id, [
                   {:moved, {:transition_run, run, "running", []}}
                 ])

        assert moved.state == "running"

        # `run` still carries the superseded version, so replaying is rejected
        # rather than overwriting the newer state.
        assert {:error, _step, :stale_state} =
                 DeliveryStore.commit(authority, project.id, [
                   {:moved, {:transition_run, run, "running", []}}
                 ])
      end

      test "rejects an illegal run transition", %{
        authority: authority,
        project: project,
        feature: feature
      } do
        {:ok, %{run: run}} =
          DeliveryStore.commit(authority, project.id, start_steps(project, feature))

        assert {:error, :moved, _reason} =
                 DeliveryStore.commit(authority, project.id, [
                   {:moved, {:transition_run, run, "completed", []}}
                 ])
      end

      test "permits only one current attempt per run", %{
        authority: authority,
        project: project,
        feature: feature
      } do
        {:ok, %{run: run, attempt: attempt}} =
          DeliveryStore.commit(authority, project.id, start_steps(project, feature))

        second = attempt_step(run, 2, 2)

        assert {:error, _step, _reason} =
                 DeliveryStore.commit(authority, project.id, [second])

        # Ending the first attempt frees the position for the next one.
        {:ok, _done} =
          DeliveryStore.commit(authority, project.id, [
            {:ended, {:transition_attempt, attempt, "superseded"}}
          ])

        assert {:ok, %{attempt: next}} =
                 DeliveryStore.commit(authority, project.id, [second])

        assert next.attempt_number == 2
      end

      test "claims and releases an attempt lease and fences its sequence", %{
        authority: authority,
        project: project,
        feature: feature
      } do
        {:ok, %{attempt: attempt}} =
          DeliveryStore.commit(authority, project.id, start_steps(project, feature))

        expires_at = DateTime.utc_now() |> DateTime.add(60, :second) |> DateTime.truncate(:second)

        assert {:ok, %{leased: leased}} =
                 DeliveryStore.commit(authority, project.id, [
                   {:leased, {:claim_lease, attempt, "worker-a", expires_at}}
                 ])

        assert leased.lease_owner == "worker-a"
        assert RunAttempt.lease_active?(leased, DateTime.utc_now())

        assert {:ok, %{observed: observed}} =
                 DeliveryStore.commit(authority, project.id, [
                   {:observed, {:observe_sequence, leased, 5}}
                 ])

        assert observed.last_sequence == 5

        # A replayed or out-of-order event cannot move the sequence back.
        assert {:error, _step, _reason} =
                 DeliveryStore.commit(authority, project.id, [
                   {:observed, {:observe_sequence, observed, 4}}
                 ])
      end

      test "keeps activity in authoritative order per feature", %{
        authority: authority,
        project: project,
        feature: feature
      } do
        for step <- 1..3 do
          {:ok, _appended} =
            DeliveryStore.commit(authority, project.id, [
              {:activity,
               {:append_activity,
                %{
                  project_id: project.id,
                  feature_id: feature.id,
                  actor_kind: "agent",
                  type: "progress",
                  payload: %{"step" => step}
                }}}
            ])
        end

        entries = DeliveryStore.list_activity(authority, project.id, feature.id)

        assert Enum.map(entries, & &1.sequence) == [1, 2, 3]
        assert Enum.map(entries, & &1.payload["step"]) == [1, 2, 3]
      end

      test "replays a command enqueued twice under one ID", %{
        authority: authority,
        project: project,
        feature: feature
      } do
        {:ok, %{run: run, attempt: attempt}} =
          DeliveryStore.commit(authority, project.id, start_steps(project, feature))

        step = command_step(project, run, attempt, Ecto.UUID.generate())

        {:ok, %{command: first}} = DeliveryStore.commit(authority, project.id, [step])
        {:ok, %{command: second}} = DeliveryStore.commit(authority, project.id, [step])

        assert second.id == first.id
        assert second.operation == "cancel"
      end

      test "claims a due command for one dispatcher and records its acknowledgement", %{
        authority: authority,
        project: project,
        feature: feature
      } do
        {:ok, %{command: command}} =
          DeliveryStore.commit(authority, project.id, start_steps(project, feature))

        assert [claimed] = DeliveryStore.claim_commands(authority, project.id, "dispatcher-a")
        assert claimed.id == command.id

        assert {:ok, acknowledged} =
                 DeliveryStore.acknowledge_command(authority, project.id, command.id, %{
                   "outcome" => "started"
                 })

        assert acknowledged.state == "acknowledged"
        assert acknowledged.result == %{"outcome" => "started"}

        # A reconnecting worker acknowledging again replays rather than
        # overwriting the recorded answer.
        assert {:ok, replayed} =
                 DeliveryStore.acknowledge_command(authority, project.id, command.id, %{
                   "outcome" => "different"
                 })

        assert replayed.result == %{"outcome" => "started"}
      end

      test "reports an unknown command rather than inventing one", %{
        authority: authority,
        project: project
      } do
        assert {:error, :not_found} =
                 DeliveryStore.acknowledge_command(
                   authority,
                   project.id,
                   Ecto.UUID.generate(),
                   %{}
                 )
      end
    end
  end

  describe "device authority creates no hosted copy" do
    @describetag authority: :device

    test "a full device commit leaves every hosted delivery table untouched", %{
      authority: authority,
      project: project,
      feature: feature
    } do
      before = hosted_counts()

      assert {:ok, results} =
               DeliveryStore.commit(authority, project.id, start_steps(project, feature))

      assert hosted_counts() == before

      # The records genuinely exist — on the device, not in PostgreSQL.
      assert {:ok, _run} = DeliveryStore.fetch_run(authority, project.id, results.run.id)
      refute Repo.get(AgentRun, results.run.id)
      refute Repo.get(RunAttempt, results.attempt.id)
      refute Repo.get(ActivityEntry, results.activity.id)
      refute Repo.get(RunCommand, results.command.id)
    end

    test "device activity is invisible to the hosted adapter and the reverse", %{
      authority: device,
      hosted: hosted,
      project: project,
      feature: feature
    } do
      {:ok, _device_side} =
        DeliveryStore.commit(device, project.id, [
          {:activity, activity_step(project, feature, %{"side" => "device"})}
        ])

      {:ok, _hosted_side} =
        DeliveryStore.commit(hosted.workspace, project.id, [
          {:activity, activity_step(project, feature, %{"side" => "hosted"})}
        ])

      device_entries = DeliveryStore.list_activity(device, project.id, feature.id)
      hosted_entries = DeliveryStore.list_activity(hosted.workspace, project.id, feature.id)

      assert Enum.map(device_entries, & &1.payload["side"]) == ["device"]
      assert Enum.map(hosted_entries, & &1.payload["side"]) == ["hosted"]
    end
  end

  describe "unsupported authority" do
    test "fails closed rather than guessing a store", %{project: project, feature: feature} do
      assert {:error, :authority, :unsupported_authority} =
               DeliveryStore.commit(:nonsense, project.id, start_steps(project, feature))

      assert :error = DeliveryStore.fetch_run(:nonsense, project.id, Ecto.UUID.generate())
      assert DeliveryStore.list_activity(:nonsense, project.id, feature.id) == []
      assert DeliveryStore.claim_commands(:nonsense, project.id, "owner") == []
    end
  end

  defp start_steps(project, feature) do
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
        }}},
      {:activity,
       {:append_activity,
        %{
          project_id: project.id,
          feature_id: feature.id,
          run_id: {:ref, :run, :id},
          attempt_id: {:ref, :attempt, :id},
          actor_kind: "system",
          type: "run_started",
          payload: %{}
        }}},
      {:command,
       {:enqueue_command,
        %{
          id: Ecto.UUID.generate(),
          project_id: project.id,
          run_id: {:ref, :run, :id},
          attempt_id: {:ref, :attempt, :id},
          operation: "start",
          expected_state_version: 1,
          manifest_digest: {:ref, :attempt, :manifest_digest}
        }}}
    ]
  end

  defp attempt_step(run, number, fence) do
    {:attempt,
     {:insert_attempt,
      %{
        run_id: run.id,
        attempt_number: number,
        continuation_reason: "manual_retry",
        effective_revision_id: run.effective_revision_id,
        effective_revision_digest: run.effective_revision_digest,
        manifest_digest: DeliveryFixtures.digest("manifest-#{run.id}-#{number}"),
        fence_token: fence
      }}}
  end

  defp command_step(project, run, _attempt, id) do
    {:command,
     {:enqueue_command,
      %{
        id: id,
        project_id: project.id,
        run_id: run.id,
        operation: "cancel",
        expected_state_version: run.state_version
      }}}
  end

  defp activity_step(project, feature, payload) do
    {:append_activity,
     %{
       project_id: project.id,
       feature_id: feature.id,
       actor_kind: "system",
       type: "progress",
       payload: payload
     }}
  end

  defp hosted_counts do
    %{
      runs: Repo.aggregate(AgentRun, :count),
      attempts: Repo.aggregate(RunAttempt, :count),
      activity: Repo.aggregate(ActivityEntry, :count),
      commands: Repo.aggregate(RunCommand, :count)
    }
  end
end
