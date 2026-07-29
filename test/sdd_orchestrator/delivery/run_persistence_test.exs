defmodule SddOrchestrator.Delivery.RunPersistenceTest do
  @moduledoc """
  Proof for run and attempt persistence (Task 15).

  The invariants under test are the ones every later orchestration task relies
  on: one run owns one branch for its lifetime, attempts are ordered and
  non-reusable, at most one attempt of a run is current, leases and fences
  cannot be revived by a superseded worker, and every write is checked against
  an expected state version.
  """
  use SddOrchestrator.DataCase, async: true

  alias Ecto.Adapters.SQL.Sandbox
  alias SddOrchestrator.Delivery.{AgentRun, RunAttempt}
  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.Repo

  setup do
    project = DeliveryFixtures.delivery_project_fixture()
    feature = DeliveryFixtures.feature_fixture(project.project, project.account)

    %{context: project, project: project.project, feature: feature, account: project.account}
  end

  describe "run creation" do
    test "starts pending with the effective revision equal to the starting revision", %{
      project: project,
      feature: feature,
      account: account
    } do
      run =
        DeliveryFixtures.run_fixture(project, feature, %{
          initiator_account_id: account.id,
          starting_revision_id: "rev-1",
          starting_revision_digest: DeliveryFixtures.digest("rev-1")
        })

      assert run.state == "pending"
      assert run.current_attempt_number == 0
      assert run.state_version == 1
      assert run.effective_revision_id == "rev-1"
      assert run.effective_revision_digest == run.starting_revision_digest
      assert run.initiator_account_id == account.id
      refute run.failure_reason
    end

    test "requires the project, feature, revision, slice, and branch", %{project: project} do
      changeset = AgentRun.create_changeset(%AgentRun{}, %{project_id: project.id})

      refute changeset.valid?

      for field <- [
            :feature_id,
            :starting_revision_id,
            :starting_revision_digest,
            :approved_slice,
            :branch
          ] do
        assert errors_on(changeset)[field]
      end
    end

    test "keeps one branch per project so two runs cannot share an isolated branch", %{
      project: project,
      feature: feature
    } do
      DeliveryFixtures.run_fixture(project, feature, %{branch: "sdd/shared"})

      assert {:error, changeset} =
               project
               |> DeliveryFixtures.run_changeset(feature, %{branch: "sdd/shared"})
               |> Repo.insert()

      assert "has already been taken" in errors_on(changeset).project_id
    end

    test "scopes a run to its own project", %{project: project, feature: feature} do
      other = DeliveryFixtures.delivery_project_fixture()
      run = DeliveryFixtures.run_fixture(project, feature)

      assert Repo.get_by(AgentRun, id: run.id, project_id: project.id)
      refute Repo.get_by(AgentRun, id: run.id, project_id: other.project.id)
    end
  end

  describe "run transitions" do
    setup %{project: project, feature: feature} do
      %{run: DeliveryFixtures.run_fixture(project, feature)}
    end

    test "applies a legal transition and bumps the state version", %{run: run} do
      assert {:ok, running} =
               run |> AgentRun.transition_changeset("running", run.state_version) |> Repo.update()

      assert running.state == "running"
      assert running.state_version == run.state_version + 1
    end

    test "rejects a move that is not in the transition table", %{run: run} do
      changeset = AgentRun.transition_changeset(run, "completed", run.state_version)

      refute changeset.valid?
      assert "cannot move from pending to completed" in errors_on(changeset).state
    end

    test "rejects a transition offered against a superseded state version", %{run: run} do
      changeset = AgentRun.transition_changeset(run, "running", run.state_version + 1)

      refute changeset.valid?
      assert "is stale" in errors_on(changeset).state_version
    end

    test "never leaves a terminal run", %{run: run} do
      {:ok, canceled} =
        run |> AgentRun.transition_changeset("canceled", run.state_version) |> Repo.update()

      for target <- AgentRun.states() do
        refute AgentRun.transition_changeset(canceled, target, canceled.state_version).valid?
      end

      assert AgentRun.terminal?(canceled)
    end

    test "records a failure reason only while failed", %{run: run} do
      {:ok, running} =
        run |> AgentRun.transition_changeset("running", run.state_version) |> Repo.update()

      {:ok, failed} =
        running
        |> AgentRun.transition_changeset("failed", running.state_version,
          failure_reason: "agent_process_exit"
        )
        |> Repo.update()

      assert failed.failure_reason == "agent_process_exit"

      # Recovering clears the reason rather than carrying a stale one forward.
      {:ok, recovered} =
        failed |> AgentRun.transition_changeset("running", failed.state_version) |> Repo.update()

      refute recovered.failure_reason
    end

    test "requires a reason when moving to failed", %{run: run} do
      {:ok, running} =
        run |> AgentRun.transition_changeset("running", run.state_version) |> Repo.update()

      changeset = AgentRun.transition_changeset(running, "failed", running.state_version)

      refute changeset.valid?
      assert errors_on(changeset).failure_reason
    end

    test "moves the attempt counter forward only", %{run: run} do
      {:ok, advanced} =
        run |> AgentRun.attempt_advance_changeset(1, run.state_version) |> Repo.update()

      assert advanced.current_attempt_number == 1

      refute AgentRun.attempt_advance_changeset(advanced, 1, advanced.state_version).valid?
      refute AgentRun.attempt_advance_changeset(advanced, 0, advanced.state_version).valid?
    end

    test "moves the effective revision without rewriting the starting revision", %{run: run} do
      {:ok, moved} =
        run
        |> AgentRun.effective_revision_changeset(
          "rev-2",
          DeliveryFixtures.digest("rev-2"),
          run.state_version
        )
        |> Repo.update()

      assert moved.effective_revision_id == "rev-2"
      assert moved.starting_revision_id == run.starting_revision_id
      assert moved.starting_revision_digest == run.starting_revision_digest
    end
  end

  describe "attempt ordering and exclusivity" do
    setup %{project: project, feature: feature} do
      %{run: DeliveryFixtures.run_fixture(project, feature)}
    end

    test "creates an ordered attempt bound to its manifest", %{run: run} do
      attempt = DeliveryFixtures.attempt_fixture(run)

      assert attempt.attempt_number == 1
      assert attempt.state == "pending"
      assert attempt.last_sequence == 0
      assert attempt.continuation_reason == "initial"
      assert attempt.manifest_digest =~ ~r/\A[0-9a-f]{64}\z/
      assert RunAttempt.current?(attempt)
    end

    test "rejects an unknown continuation reason", %{run: run} do
      changeset =
        RunAttempt.create_changeset(%RunAttempt{}, %{
          run_id: run.id,
          attempt_number: 1,
          continuation_reason: "because",
          effective_revision_id: run.effective_revision_id,
          effective_revision_digest: run.effective_revision_digest,
          manifest_digest: DeliveryFixtures.digest("m"),
          fence_token: 1
        })

      refute changeset.valid?
      assert errors_on(changeset).continuation_reason
    end

    test "never reuses an attempt number within one run", %{run: run} do
      DeliveryFixtures.attempt_fixture(run, %{attempt_number: 1})

      assert {:error, changeset} =
               run
               |> DeliveryFixtures.attempt_changeset(%{attempt_number: 1, fence_token: 2})
               |> Repo.insert()

      assert "has already been taken" in errors_on(changeset).run_id
    end

    test "permits at most one current attempt per run", %{run: run} do
      DeliveryFixtures.attempt_fixture(run, %{attempt_number: 1, fence_token: 1})

      assert {:error, changeset} =
               run
               |> DeliveryFixtures.attempt_changeset(%{attempt_number: 2, fence_token: 2})
               |> Repo.insert()

      assert errors_on(changeset).state == ["has already been taken"]
    end

    test "permits the next attempt once the current one is terminal", %{run: run} do
      first = DeliveryFixtures.attempt_fixture(run, %{attempt_number: 1, fence_token: 1})

      {:ok, _superseded} =
        first
        |> RunAttempt.transition_changeset("superseded", first.state_version)
        |> Repo.update()

      second = DeliveryFixtures.attempt_fixture(run, %{attempt_number: 2, fence_token: 2})

      assert second.attempt_number == 2
      assert Repo.aggregate(RunAttempt, :count) == 2
    end

    test "keeps fence tokens unique within one run", %{run: run} do
      first = DeliveryFixtures.attempt_fixture(run, %{attempt_number: 1, fence_token: 7})

      {:ok, _done} =
        first |> RunAttempt.transition_changeset("failed", first.state_version) |> Repo.update()

      assert {:error, changeset} =
               run
               |> DeliveryFixtures.attempt_changeset(%{attempt_number: 2, fence_token: 7})
               |> Repo.insert()

      assert "has already been taken" in errors_on(changeset).run_id
    end

    test "two concurrent inserts produce exactly one current attempt", %{run: run} do
      parent = self()

      tasks =
        for number <- [1, 2] do
          Task.async(fn ->
            Sandbox.allow(Repo, parent, self())

            run
            |> DeliveryFixtures.attempt_changeset(%{
              attempt_number: number,
              fence_token: number
            })
            |> Repo.insert()
            |> case do
              {:ok, _attempt} -> :inserted
              {:error, _changeset} -> :rejected
            end
          end)
        end

      results = Enum.map(tasks, &Task.await/1)

      assert Enum.count(results, &(&1 == :inserted)) == 1
      assert Enum.count(results, &(&1 == :rejected)) == 1
      assert Repo.aggregate(RunAttempt, :count) == 1
    end
  end

  describe "attempt leases and fences" do
    setup %{project: project, feature: feature} do
      run = DeliveryFixtures.run_fixture(project, feature)
      %{run: run, attempt: DeliveryFixtures.attempt_fixture(run)}
    end

    test "claims a lease for one worker until its expiry", %{attempt: attempt} do
      expires_at = DateTime.utc_now() |> DateTime.add(60, :second) |> DateTime.truncate(:second)

      {:ok, leased} =
        attempt
        |> RunAttempt.claim_lease_changeset("worker-a", expires_at, attempt.state_version)
        |> Repo.update()

      assert leased.lease_owner == "worker-a"
      assert RunAttempt.lease_active?(leased, DateTime.utc_now())
      refute RunAttempt.lease_active?(leased, DateTime.add(expires_at, 1, :second))
    end

    test "an unleased attempt is never treated as held", %{attempt: attempt} do
      refute RunAttempt.lease_active?(attempt, DateTime.utc_now())
    end

    test "a terminal attempt cannot be claimed by a late worker", %{attempt: attempt} do
      {:ok, done} =
        attempt
        |> RunAttempt.transition_changeset("failed", attempt.state_version)
        |> Repo.update()

      expires_at = DateTime.utc_now() |> DateTime.add(60, :second) |> DateTime.truncate(:second)

      changeset =
        RunAttempt.claim_lease_changeset(done, "worker-a", expires_at, done.state_version)

      refute changeset.valid?
      assert "is not a current attempt" in errors_on(changeset).state
    end

    test "reaching a terminal state releases the lease", %{attempt: attempt} do
      expires_at = DateTime.utc_now() |> DateTime.add(60, :second) |> DateTime.truncate(:second)

      {:ok, leased} =
        attempt
        |> RunAttempt.claim_lease_changeset("worker-a", expires_at, attempt.state_version)
        |> Repo.update()

      {:ok, dispatched} =
        leased
        |> RunAttempt.transition_changeset("dispatched", leased.state_version)
        |> Repo.update()

      {:ok, canceled} =
        dispatched
        |> RunAttempt.transition_changeset("canceled", dispatched.state_version)
        |> Repo.update()

      refute canceled.lease_owner
      refute canceled.lease_expires_at
      refute RunAttempt.lease_active?(canceled, DateTime.utc_now())
    end

    test "the observed event sequence only moves forward", %{attempt: attempt} do
      {:ok, observed} =
        attempt
        |> RunAttempt.observe_sequence_changeset(5, attempt.state_version)
        |> Repo.update()

      assert observed.last_sequence == 5

      refute RunAttempt.observe_sequence_changeset(observed, 5, observed.state_version).valid?
      refute RunAttempt.observe_sequence_changeset(observed, 4, observed.state_version).valid?
      assert RunAttempt.observe_sequence_changeset(observed, 6, observed.state_version).valid?
    end

    test "rejects an attempt transition against a superseded state version", %{attempt: attempt} do
      changeset =
        RunAttempt.transition_changeset(attempt, "dispatched", attempt.state_version + 1)

      refute changeset.valid?
      assert "is stale" in errors_on(changeset).state_version
    end
  end

  describe "device-adapter value shape" do
    setup %{project: project, feature: feature} do
      run = DeliveryFixtures.run_fixture(project, feature)
      %{run: run, attempt: DeliveryFixtures.attempt_fixture(run)}
    end

    test "a run round-trips through its plain value", %{run: run} do
      assert {:ok, restored} = run |> AgentRun.to_value() |> AgentRun.from_value()

      assert restored.id == run.id
      assert restored.branch == run.branch
      assert restored.state == run.state
      assert restored.effective_revision_digest == run.effective_revision_digest
    end

    test "an attempt round-trips through its plain value, including its lease", %{
      attempt: attempt
    } do
      expires_at = DateTime.utc_now() |> DateTime.add(60, :second) |> DateTime.truncate(:second)

      {:ok, leased} =
        attempt
        |> RunAttempt.claim_lease_changeset("worker-a", expires_at, attempt.state_version)
        |> Repo.update()

      assert {:ok, restored} = leased |> RunAttempt.to_value() |> RunAttempt.from_value()

      assert restored.attempt_number == leased.attempt_number
      assert restored.fence_token == leased.fence_token
      assert restored.lease_owner == "worker-a"
      assert DateTime.compare(restored.lease_expires_at, expires_at) == :eq
    end

    test "an unusable value is rejected rather than partially restored" do
      assert {:error, :invalid_run_value} = AgentRun.from_value(%{"state" => "nope"})
      assert {:error, :invalid_run_value} = AgentRun.from_value("run")
      assert {:error, :invalid_attempt_value} = RunAttempt.from_value(%{"attempt_number" => 0})
      assert {:error, :invalid_attempt_value} = RunAttempt.from_value(%{})
    end
  end
end
