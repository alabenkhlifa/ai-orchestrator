defmodule SddOrchestrator.Worker.RunStateTest do
  @moduledoc """
  Task 4 proof: worker-local durable run-state storage — round-tripping,
  owner-only permissions, and typed refusal on a corrupt or incomplete
  stored file — all without touching the database. The command-handling
  decisions that read and write this storage (duplicate, stale fence,
  superseded attempt, restart recovery) live in
  `SddOrchestrator.Worker.CommandHandlingTest`.
  """

  use ExUnit.Case, async: true

  alias SddOrchestrator.Worker.RunState

  defp tmp_home(context) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "worker-run-state-test-#{context.test}-#{System.unique_integer([:positive])}"
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
          last_sequence: 0,
          agent_thread_ref: nil,
          lifecycle: "accepted"
        },
        overrides
      )
    )
  end

  describe "no state yet" do
    test "a worker that never received a command loads an empty record, not an error", context do
      home = tmp_home(context)
      refute File.exists?(home)

      assert RunState.load(home) == {:ok, RunState.empty()}
    end
  end

  describe "round trip" do
    test "a stored current entry round-trips exactly", context do
      home = tmp_home(context)
      current = entry()

      assert :ok = RunState.store(%{current: current, previous: nil}, home)
      assert {:ok, %{current: ^current, previous: nil}} = RunState.load(home)
    end

    test "a stored current and previous entry both round-trip", context do
      home = tmp_home(context)
      current = entry(%{attempt_number: 2, fence_token: 2})
      previous = entry(%{attempt_number: 1, fence_token: 1, lifecycle: "stopped"})

      assert :ok = RunState.store(%{current: current, previous: previous}, home)
      assert {:ok, %{current: ^current, previous: ^previous}} = RunState.load(home)
    end

    test "an agent_thread_ref of nil round-trips", context do
      home = tmp_home(context)
      current = entry(%{agent_thread_ref: nil})

      :ok = RunState.store(%{current: current, previous: nil}, home)

      assert {:ok, %{current: %RunState{agent_thread_ref: nil}}} = RunState.load(home)
    end
  end

  describe "owner-only permissions" do
    test "the run-state file and its directory are restricted to owner-only", context do
      home = tmp_home(context)
      :ok = RunState.store(%{current: entry(), previous: nil}, home)

      assert File.stat!(home).mode |> rem(0o1000) == 0o700
      assert File.stat!(RunState.path(home)).mode |> rem(0o1000) == 0o600
    end
  end

  describe "corrupt or incomplete storage" do
    test "unreadable JSON refuses with a typed reason", context do
      home = tmp_home(context)
      File.mkdir_p!(home)
      File.write!(RunState.path(home), "not valid json")

      assert {:error, {:invalid_run_state, {:invalid_json, _reason}}} = RunState.load(home)
    end

    test "a JSON array instead of an object refuses with a typed reason", context do
      home = tmp_home(context)
      File.mkdir_p!(home)
      File.write!(RunState.path(home), Jason.encode!([1, 2, 3]))

      assert {:error, {:invalid_run_state, :not_an_object}} = RunState.load(home)
    end

    test "an entry missing a required field refuses with a typed reason", context do
      home = tmp_home(context)
      File.mkdir_p!(home)

      incomplete = entry() |> Map.from_struct() |> Map.delete(:fence_token)

      File.write!(
        RunState.path(home),
        Jason.encode!(%{"current" => stringify(incomplete), "previous" => nil})
      )

      assert {:error, {:invalid_run_state, {:missing_field, "fence_token"}}} = RunState.load(home)
    end

    test "an entry with an unrecognized lifecycle refuses with a typed reason", context do
      home = tmp_home(context)
      File.mkdir_p!(home)

      invalid = entry(%{lifecycle: "napping"}) |> Map.from_struct() |> stringify()

      File.write!(RunState.path(home), Jason.encode!(%{"current" => invalid, "previous" => nil}))

      assert {:error, {:invalid_run_state, {:invalid_lifecycle, "napping"}}} = RunState.load(home)
    end
  end

  defp stringify(map) do
    Map.new(map, fn {key, value} -> {Atom.to_string(key), value} end)
  end
end
