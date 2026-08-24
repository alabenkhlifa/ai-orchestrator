defmodule SddOrchestrator.Worker.RunStateRetentionTest do
  @moduledoc """
  Task 7 proof: the worker-local provider-thread reference expires on the
  device once its attempt is finished and the retention window has passed —
  and nothing else in the run state moves with it. Storage round-tripping
  and typed refusal on a corrupt file live in
  `SddOrchestrator.Worker.RunStateTest`; the acceptance decisions that read
  the reference forward live in
  `SddOrchestrator.Worker.CommandHandlingTest`.
  """

  # Never touches the database or application env: every case passes its own
  # temporary worker home explicitly.
  use ExUnit.Case, async: true

  alias SddOrchestrator.Worker.RunState
  alias SddOrchestrator.Worker.RunStateRetention

  @window RunStateRetention.window()

  defp tmp_home(context) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "worker-run-state-retention-test-#{context.test}-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp entry(overrides \\ %{}) do
    struct!(
      RunState,
      Map.merge(
        %{
          command_id: "cmd_#{System.unique_integer([:positive])}",
          operation: "start",
          project_id: "prj_1",
          feature_id: "ftr_1",
          run_id: "run_1",
          attempt_number: 1,
          fence_token: 1,
          manifest_digest: String.duplicate("a", 64),
          last_sequence: 3,
          agent_thread_ref: "thread_abc123",
          branch: "sdd/feature/ftr-0001/run-0001",
          lifecycle: "verification_completed"
        },
        overrides
      )
    )
  end

  # Stores the snapshot and backdates the run-state file to the moment of
  # its last transition, which is what the sweep reads the age from.
  defp store_transitioned(home, snapshot, now, seconds_ago) do
    :ok = RunState.store(snapshot, home)
    File.touch!(RunState.path(home), DateTime.to_unix(now) - seconds_ago)
    :ok
  end

  defp stored(home), do: home |> RunState.path() |> File.read!() |> Jason.decode!()

  describe "expiry window" do
    test "a finished attempt loses its provider thread at the window boundary", context do
      home = tmp_home(context)
      now = DateTime.utc_now()

      store_transitioned(home, %{current: entry(), previous: nil}, now, @window)

      assert {:ok, 1} = RunStateRetention.prune(now, home)
      assert {:ok, %{current: %RunState{agent_thread_ref: nil}}} = RunState.load(home)
    end

    test "a finished attempt one second inside the window keeps it", context do
      home = tmp_home(context)
      now = DateTime.utc_now()

      store_transitioned(home, %{current: entry(), previous: nil}, now, @window - 1)

      assert {:ok, 0} = RunStateRetention.prune(now, home)

      assert {:ok, %{current: %RunState{agent_thread_ref: "thread_abc123"}}} =
               RunState.load(home)
    end

    test "every terminal lifecycle expires, and only those", context do
      now = DateTime.utc_now()

      for lifecycle <- RunState.lifecycle_states() do
        home = tmp_home(context)
        terminal? = lifecycle in RunState.terminal_lifecycle_states()

        store_transitioned(
          home,
          %{current: entry(%{lifecycle: lifecycle}), previous: nil},
          now,
          @window
        )

        expected_removed = if terminal?, do: 1, else: 0
        expected_ref = if terminal?, do: nil, else: "thread_abc123"

        assert {:ok, ^expected_removed} = RunStateRetention.prune(now, home)
        assert {:ok, %{current: %RunState{agent_thread_ref: ^expected_ref}}} = RunState.load(home)
      end
    end
  end

  describe "an attempt still in flight" do
    test "keeps its provider thread however old the record is", context do
      home = tmp_home(context)
      now = DateTime.utc_now()

      store_transitioned(
        home,
        %{current: entry(%{lifecycle: "accepted"}), previous: nil},
        now,
        @window * 40
      )

      assert {:ok, 0} = RunStateRetention.prune(now, home)

      assert {:ok, %{current: %RunState{agent_thread_ref: "thread_abc123"}}} =
               RunState.load(home)
    end
  end

  describe "the two slots" do
    test "a superseded previous attempt expires while the accepted current one does not",
         context do
      home = tmp_home(context)
      now = DateTime.utc_now()

      snapshot = %{
        current: entry(%{attempt_number: 2, fence_token: 2, lifecycle: "accepted"}),
        previous: entry(%{agent_thread_ref: "thread_previous", lifecycle: "stopped"})
      }

      store_transitioned(home, snapshot, now, @window)

      assert {:ok, 1} = RunStateRetention.prune(now, home)

      assert {:ok,
              %{
                current: %RunState{agent_thread_ref: "thread_abc123"},
                previous: %RunState{agent_thread_ref: nil}
              }} = RunState.load(home)
    end

    test "both slots expire together when both attempts are finished", context do
      home = tmp_home(context)
      now = DateTime.utc_now()

      snapshot = %{
        current: entry(%{attempt_number: 2, fence_token: 2, lifecycle: "failed"}),
        previous: entry(%{agent_thread_ref: "thread_previous", lifecycle: "stopped"})
      }

      store_transitioned(home, snapshot, now, @window)

      assert {:ok, 2} = RunStateRetention.prune(now, home)

      assert {:ok,
              %{
                current: %RunState{agent_thread_ref: nil},
                previous: %RunState{agent_thread_ref: nil}
              }} = RunState.load(home)
    end
  end

  describe "everything else in the record" do
    test "only the provider thread changes", context do
      home = tmp_home(context)
      now = DateTime.utc_now()

      snapshot = %{
        current: entry(%{attempt_number: 2, fence_token: 7, last_sequence: 41}),
        previous: entry(%{agent_thread_ref: "thread_previous", lifecycle: "stopped"})
      }

      store_transitioned(home, snapshot, now, @window)
      before = stored(home)

      assert {:ok, 2} = RunStateRetention.prune(now, home)

      expected =
        before
        |> put_in(["current", "agent_thread_ref"], nil)
        |> put_in(["previous", "agent_thread_ref"], nil)

      assert stored(home) == expected
    end

    test "the run-state file and its directory stay owner-only", context do
      home = tmp_home(context)
      now = DateTime.utc_now()

      store_transitioned(home, %{current: entry(), previous: nil}, now, @window)

      assert {:ok, 1} = RunStateRetention.prune(now, home)

      assert File.stat!(home).mode |> Bitwise.band(0o777) == 0o700
      assert File.stat!(RunState.path(home)).mode |> Bitwise.band(0o777) == 0o600
    end
  end

  describe "nothing to expire" do
    test "a worker that has never run is a successful no-op", context do
      home = tmp_home(context)
      refute File.exists?(home)

      assert {:ok, 0} = RunStateRetention.prune(DateTime.utc_now(), home)
      refute File.exists?(RunState.path(home))
    end

    test "an unreadable run-state file is a successful no-op, not a crash", context do
      home = tmp_home(context)
      now = DateTime.utc_now()

      File.mkdir_p!(home)
      File.write!(RunState.path(home), "not valid json")
      File.touch!(RunState.path(home), DateTime.to_unix(now) - @window)

      assert {:ok, 0} = RunStateRetention.prune(now, home)
      assert File.read!(RunState.path(home)) == "not valid json"
    end

    test "a finished attempt that never launched an agent leaves the file untouched", context do
      home = tmp_home(context)
      now = DateTime.utc_now()

      store_transitioned(
        home,
        %{current: entry(%{agent_thread_ref: nil}), previous: nil},
        now,
        @window
      )

      before = stored(home)

      assert {:ok, 0} = RunStateRetention.prune(now, home)
      assert stored(home) == before
    end
  end

  describe "idempotence" do
    test "a second sweep removes nothing and changes nothing", context do
      home = tmp_home(context)
      now = DateTime.utc_now()

      store_transitioned(home, %{current: entry(), previous: nil}, now, @window)

      assert {:ok, 1} = RunStateRetention.prune(now, home)
      after_first = stored(home)

      assert {:ok, 0} = RunStateRetention.prune(now, home)
      assert stored(home) == after_first
    end
  end
end
