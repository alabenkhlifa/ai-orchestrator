defmodule SddOrchestrator.Delivery.CommandOutboxTest do
  @moduledoc """
  Proof for the durable command outbox and dispatcher (Task 16).

  The properties under test are the ones that let a run survive a restart: a
  command exists only if its state change committed, one instruction produces
  one row no matter how often it is enqueued, two dispatchers never deliver the
  same command, an abandoned claim returns to the queue, and an acknowledgement
  is recorded once and replayed thereafter.
  """
  use SddOrchestrator.DataCase, async: true

  alias Ecto.Adapters.SQL.Sandbox
  alias Ecto.Multi
  alias SddOrchestrator.CommandTransportDouble
  alias SddOrchestrator.Delivery.{CommandOutbox, Dispatcher, RunCommand}
  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.Repo

  setup do
    context = DeliveryFixtures.delivery_project_fixture()
    feature = DeliveryFixtures.feature_fixture(context.project, context.account)
    run = DeliveryFixtures.run_fixture(context.project, feature)
    attempt = DeliveryFixtures.attempt_fixture(run)

    %{project: context.project, feature: feature, run: run, attempt: attempt}
  end

  describe "enqueue" do
    test "records a start command bound to its manifest", %{run: run, attempt: attempt} do
      assert {:ok, command} = enqueue(run, attempt)

      assert command.operation == "start"
      assert command.state == "pending"
      assert command.delivery_count == 0
      assert command.manifest_digest == attempt.manifest_digest
      assert command.expected_state_version == run.state_version
    end

    test "one instruction enqueued twice is one row that replays its record", %{
      run: run,
      attempt: attempt
    } do
      id = Ecto.UUID.generate()

      {:ok, first} = enqueue(run, attempt, id: id)
      {:ok, _acknowledged} = CommandOutbox.acknowledge(first, %{"outcome" => "started"})
      {:ok, second} = enqueue(run, attempt, id: id)

      assert second.id == first.id
      assert second.state == "acknowledged"
      assert second.result == %{"outcome" => "started"}
      assert Repo.aggregate(RunCommand, :count) == 1
    end

    test "reusing one command ID for a different instruction is surfaced", %{
      run: run,
      attempt: attempt
    } do
      id = Ecto.UUID.generate()
      {:ok, _start} = enqueue(run, attempt, id: id)

      assert {:error, :command_id_reused} =
               CommandOutbox.enqueue(%{
                 id: id,
                 project_id: run.project_id,
                 run_id: run.id,
                 operation: "cancel",
                 expected_state_version: run.state_version
               })
    end

    test "an execution command must name its manifest and a control command must not", %{
      run: run,
      attempt: attempt
    } do
      assert {:error, changeset} =
               CommandOutbox.enqueue(%{
                 id: Ecto.UUID.generate(),
                 project_id: run.project_id,
                 run_id: run.id,
                 attempt_id: attempt.id,
                 operation: "start",
                 expected_state_version: run.state_version
               })

      assert errors_on(changeset).manifest_digest

      assert {:error, control} =
               CommandOutbox.enqueue(%{
                 id: Ecto.UUID.generate(),
                 project_id: run.project_id,
                 run_id: run.id,
                 operation: "cancel",
                 expected_state_version: run.state_version,
                 manifest_digest: attempt.manifest_digest
               })

      assert errors_on(control).manifest_digest
    end

    test "rejects an unknown operation", %{run: run} do
      assert {:error, changeset} =
               CommandOutbox.enqueue(%{
                 id: Ecto.UUID.generate(),
                 project_id: run.project_id,
                 run_id: run.id,
                 operation: "explode",
                 expected_state_version: run.state_version
               })

      assert errors_on(changeset).operation
    end

    test "rolls back with the caller's transaction", %{run: run, attempt: attempt} do
      result =
        Multi.new()
        |> CommandOutbox.enqueue_multi(:command, command_attrs(run, attempt))
        |> Multi.run(:boom, fn _repo, _changes -> {:error, :injected} end)
        |> Repo.transaction()

      assert {:error, :boom, :injected, _changes} = result
      assert Repo.aggregate(RunCommand, :count) == 0
    end

    test "names a record created earlier in the same transaction", %{run: run, attempt: attempt} do
      {:ok, %{command: command}} =
        Multi.new()
        |> Multi.run(:attempt, fn _repo, _changes -> {:ok, attempt} end)
        |> CommandOutbox.enqueue_multi(:command, fn %{attempt: created} ->
          command_attrs(run, created)
        end)
        |> Repo.transaction()

      assert command.attempt_id == attempt.id
    end
  end

  describe "claiming" do
    test "claims a due command and leases it to one owner", %{run: run, attempt: attempt} do
      {:ok, _command} = enqueue(run, attempt)

      assert [claimed] = CommandOutbox.claim("dispatcher-a")
      assert claimed.state == "claimed"
      assert claimed.claimed_by == "dispatcher-a"
      assert RunCommand.claim_active?(claimed, DateTime.utc_now())
    end

    test "does not claim a command that is not due yet", %{run: run, attempt: attempt} do
      due_at = DateTime.utc_now() |> DateTime.add(300, :second)
      {:ok, _command} = enqueue(run, attempt, due_at: due_at)

      assert CommandOutbox.claim("dispatcher-a") == []
      assert CommandOutbox.pending_count() == 0
      assert [_later] = CommandOutbox.claim("dispatcher-a", now: DateTime.add(due_at, 1, :second))
    end

    test "a second dispatcher takes different rows, never the same one", %{
      run: run,
      attempt: attempt
    } do
      {:ok, _first} = enqueue(run, attempt)
      {:ok, _second} = enqueue(run, attempt, id: Ecto.UUID.generate(), operation: "reconcile")

      first_claim = CommandOutbox.claim("dispatcher-a", limit: 1)
      second_claim = CommandOutbox.claim("dispatcher-b", limit: 1)

      assert length(first_claim) == 1
      assert length(second_claim) == 1
      refute hd(first_claim).id == hd(second_claim).id
    end

    test "two concurrent dispatchers never claim one command twice", %{
      run: run,
      attempt: attempt
    } do
      {:ok, _command} = enqueue(run, attempt)
      parent = self()

      claims =
        for owner <- ["a", "b"] do
          Task.async(fn ->
            Sandbox.allow(Repo, parent, self())
            CommandOutbox.claim(owner)
          end)
        end
        |> Enum.map(&Task.await/1)
        |> List.flatten()

      assert length(claims) == 1
    end

    test "an already claimed command is not claimed again until its lease expires", %{
      run: run,
      attempt: attempt
    } do
      {:ok, _command} = enqueue(run, attempt)

      assert [_claimed] = CommandOutbox.claim("dispatcher-a", lease_seconds: 60)
      assert CommandOutbox.claim("dispatcher-b") == []

      later = DateTime.utc_now() |> DateTime.add(61, :second)
      assert [reclaimed] = CommandOutbox.claim("dispatcher-b", now: later)
      assert reclaimed.claimed_by == "dispatcher-b"
    end
  end

  describe "restart recovery" do
    test "an abandoned claim returns to the queue when its lease expires", %{
      run: run,
      attempt: attempt
    } do
      {:ok, _command} = enqueue(run, attempt)
      [claimed] = CommandOutbox.claim("dispatcher-that-died", lease_seconds: 1)

      later = DateTime.utc_now() |> DateTime.add(60, :second)

      assert CommandOutbox.release_expired(now: later) == 1

      returned = Repo.get!(RunCommand, claimed.id)
      assert returned.state == "pending"
      refute returned.claimed_by
      refute returned.claim_expires_at
    end

    test "a live claim is left alone", %{run: run, attempt: attempt} do
      {:ok, _command} = enqueue(run, attempt)
      CommandOutbox.claim("dispatcher-a", lease_seconds: 600)

      assert CommandOutbox.release_expired() == 0
    end

    test "an acknowledged command is never returned to the queue", %{
      run: run,
      attempt: attempt
    } do
      {:ok, command} = enqueue(run, attempt)
      CommandOutbox.claim("dispatcher-a", lease_seconds: 1)
      {:ok, _acknowledged} = CommandOutbox.acknowledge(command.id, %{"outcome" => "started"})

      later = DateTime.utc_now() |> DateTime.add(600, :second)

      assert CommandOutbox.release_expired(now: later) == 0
      assert Repo.get!(RunCommand, command.id).state == "acknowledged"
    end
  end

  describe "acknowledgement and replay" do
    test "records the worker's result once and replays it thereafter", %{
      run: run,
      attempt: attempt
    } do
      {:ok, command} = enqueue(run, attempt)

      {:ok, acknowledged} = CommandOutbox.acknowledge(command, %{"outcome" => "started"})
      {:ok, replayed} = CommandOutbox.acknowledge(acknowledged, %{"outcome" => "different"})

      assert replayed.result == %{"outcome" => "started"}
      assert replayed.acknowledged_at == acknowledged.acknowledged_at
    end

    test "releases the claim on acknowledgement", %{run: run, attempt: attempt} do
      {:ok, _command} = enqueue(run, attempt)
      [claimed] = CommandOutbox.claim("dispatcher-a")

      {:ok, acknowledged} = CommandOutbox.acknowledge(claimed, %{})

      refute acknowledged.claimed_by
      refute acknowledged.claim_expires_at
    end

    test "rejects an oversized result rather than storing it", %{run: run, attempt: attempt} do
      {:ok, command} = enqueue(run, attempt)
      oversized = %{"log" => String.duplicate("x", 5_000)}

      assert {:error, changeset} = CommandOutbox.acknowledge(command, oversized)
      assert errors_on(changeset).result
    end

    test "acknowledging an unknown command reports not found" do
      assert {:error, :not_found} = CommandOutbox.acknowledge(Ecto.UUID.generate(), %{})
    end

    test "records a terminal delivery failure with its code", %{run: run, attempt: attempt} do
      {:ok, command} = enqueue(run, attempt)

      assert {:ok, failed} = CommandOutbox.fail(command, "incompatible_worker")
      assert failed.state == "failed"
      assert failed.failure_code == "incompatible_worker"
      assert RunCommand.terminal?(failed)
    end
  end

  describe "dispatcher" do
    setup do
      restore = CommandTransportDouble.install()
      on_exit(restore)
      :ok
    end

    test "delivers a due command through the configured transport", %{
      run: run,
      attempt: attempt
    } do
      {:ok, command} = enqueue(run, attempt)

      assert %{delivered: 1} = Dispatcher.dispatch_now(owner: "test-dispatcher")

      assert [handed] = CommandTransportDouble.delivered()
      assert handed.id == command.id

      stored = Repo.get!(RunCommand, command.id)
      assert stored.state == "delivered"
      assert stored.delivery_count == 1
      assert stored.delivered_at
    end

    test "leaves the command queued when no worker is connected", %{run: run, attempt: attempt} do
      CommandTransportDouble.script({:error, :no_worker})
      {:ok, command} = enqueue(run, attempt)

      assert %{delivered: 0} = Dispatcher.dispatch_now(owner: "test-dispatcher")

      stored = Repo.get!(RunCommand, command.id)
      assert stored.state == "claimed"
      assert stored.delivery_count == 0
    end

    test "returns abandoned claims to the queue before claiming", %{run: run, attempt: attempt} do
      {:ok, command} = enqueue(run, attempt)
      CommandOutbox.claim("dispatcher-that-died", lease_seconds: -10)

      assert %{released: 1, delivered: 1} = Dispatcher.dispatch_now(owner: "test-dispatcher")
      assert Repo.get!(RunCommand, command.id).state == "delivered"
    end

    test "delivers nothing when the queue is empty" do
      assert %{released: 0, delivered: 0} = Dispatcher.dispatch_now(owner: "test-dispatcher")
      assert CommandTransportDouble.delivered() == []
    end

    test "the default transport keeps work queued rather than losing it", %{
      run: run,
      attempt: attempt
    } do
      Application.put_env(
        :sdd_orchestrator,
        :command_transport,
        SddOrchestrator.Delivery.CommandTransport.Unavailable
      )

      {:ok, command} = enqueue(run, attempt)

      assert %{delivered: 0} = Dispatcher.dispatch_now(owner: "test-dispatcher")
      assert Repo.get!(RunCommand, command.id).state == "claimed"
    end
  end

  describe "run scoping and value shape" do
    test "lists one run's commands in due order", %{run: run, attempt: attempt} do
      {:ok, first} = enqueue(run, attempt)

      {:ok, second} =
        enqueue(run, attempt,
          id: Ecto.UUID.generate(),
          operation: "cancel",
          due_at: DateTime.add(DateTime.utc_now(), 60, :second)
        )

      assert Enum.map(CommandOutbox.for_run(run.id), & &1.id) == [first.id, second.id]
      assert CommandOutbox.for_run("not-a-uuid") == []
    end

    test "round-trips through its plain value", %{run: run, attempt: attempt} do
      {:ok, command} = enqueue(run, attempt)

      assert {:ok, restored} = command |> RunCommand.to_value() |> RunCommand.from_value()

      assert restored.id == command.id
      assert restored.operation == "start"
      assert restored.manifest_digest == command.manifest_digest
    end

    test "an unusable value is rejected rather than partially restored" do
      assert {:error, :invalid_command_value} = RunCommand.from_value(%{"operation" => "nope"})
      assert {:error, :invalid_command_value} = RunCommand.from_value(%{})
      assert {:error, :invalid_command_value} = RunCommand.from_value("command")
    end
  end

  defp enqueue(run, attempt, overrides \\ []) do
    run
    |> command_attrs(attempt)
    |> Map.merge(Map.new(overrides))
    |> then(fn attrs ->
      if attrs[:operation] in ~w(cancel reconcile) do
        attrs |> Map.delete(:manifest_digest) |> Map.delete(:attempt_id)
      else
        attrs
      end
    end)
    |> CommandOutbox.enqueue()
  end

  defp command_attrs(run, attempt) do
    %{
      id: Ecto.UUID.generate(),
      project_id: run.project_id,
      run_id: run.id,
      attempt_id: attempt.id,
      operation: "start",
      expected_state_version: run.state_version,
      manifest_digest: attempt.manifest_digest
    }
  end
end
