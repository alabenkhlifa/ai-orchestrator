defmodule Mix.Tasks.Worker.StartTest do
  @moduledoc """
  Task 2 proof: the `mix worker.start` CLI surface, exercised through its
  factored `start/1` (the part before the task blocks the process alive
  forever with `Process.sleep(:infinity)`, which is deliberately not
  exercised here). Confirms a missing or invalid configuration refuses
  startup with a clear, actionable `Mix.Error` rather than partially
  starting, and that a valid configuration starts the worker supervisor.
  """

  use ExUnit.Case, async: true

  alias SddOrchestrator.Worker.Configuration

  @valid_fields %{
    control_plane_address: "http://localhost:4000",
    device_workspace_id: Ecto.UUID.generate(),
    worker_credential: "worker-credential-secret",
    agent_adapter: "claude_code",
    agent_executable: "/usr/local/bin/claude",
    workspace_root: "/Users/dev/project"
  }

  defp tmp_home(context) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "worker-start-cli-test-#{context.test}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  test "refuses to start with a clear message when never paired", context do
    home = tmp_home(context)

    assert_raise Mix.Error, ~r/mix worker\.pair/, fn ->
      Mix.Tasks.Worker.Start.start(["--home", home])
    end
  end

  test "refuses to start with a clear message when the configuration is corrupt", context do
    home = tmp_home(context)
    File.mkdir_p!(home)
    File.write!(Configuration.path(home), "not valid json")

    assert_raise Mix.Error, ~r/invalid/, fn ->
      Mix.Tasks.Worker.Start.start(["--home", home])
    end
  end

  test "starts the worker supervisor with a valid stored configuration", context do
    home = tmp_home(context)
    :ok = Configuration.store(struct!(Configuration, @valid_fields), home)

    # Started directly (linked) from this test process rather than through
    # `start_supervised!/1`, since `start/1` wraps the real
    # `mix worker.start` CLI entry point. Left running: it is unnamed and
    # its link to this test process tears it down once the test ends, so no
    # manual stop is needed (and adding one would race that teardown).
    assert {:ok, pid} = Mix.Tasks.Worker.Start.start(["--home", home])

    assert Process.alive?(pid)
  end
end
