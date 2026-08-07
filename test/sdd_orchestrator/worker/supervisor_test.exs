defmodule SddOrchestrator.Worker.SupervisorTest do
  @moduledoc """
  Task 2 proof: `SddOrchestrator.Worker.Supervisor` refuses to start with a
  typed reason on missing or invalid configuration rather than starting
  partially, and, once started with valid configuration, its children never
  include a database repo.
  """

  # Task 7's agent-adapter-selection tests mutate the process-wide
  # `:agent_adapter`/`:agent_executable` `Application` env, the same keys
  # `ClaudeCodeTest` and `CodexTest` mutate — `async: true` would race
  # concurrently-running tests over that shared global state.
  use ExUnit.Case, async: false

  alias SddOrchestrator.Worker.Configuration
  alias SddOrchestrator.Worker.State
  alias SddOrchestrator.Worker.Supervisor, as: WorkerSupervisor

  @valid_fields %{
    control_plane_address: "http://localhost:4000",
    device_workspace_id: Ecto.UUID.generate(),
    worker_credential: "worker-credential-secret",
    agent_adapter: "claude_code",
    agent_executable: "/usr/local/bin/claude",
    workspace_root: "/Users/dev/project",
    project_id: Ecto.UUID.generate(),
    worker_id: Ecto.UUID.generate()
  }

  defp tmp_home(context) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "worker-supervisor-test-#{context.test}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  test "refuses to start when no configuration has ever been stored", context do
    home = tmp_home(context)
    refute File.exists?(home)

    assert {:error, :not_paired} = WorkerSupervisor.start_link(home: home)
  end

  test "refuses to start when the stored configuration is corrupt", context do
    home = tmp_home(context)
    File.mkdir_p!(home)
    File.write!(Configuration.path(home), "not valid json")

    assert {:error, {:invalid_configuration, _reason}} = WorkerSupervisor.start_link(home: home)
  end

  test "starts with valid configuration and holds it in worker state", context do
    home = tmp_home(context)
    config = struct!(Configuration, @valid_fields)
    :ok = Configuration.store(config, home)

    pid = start_supervised!({WorkerSupervisor, home: home})

    assert WorkerSupervisor.configuration(pid) == config
  end

  test "started children never include a database repo", context do
    home = tmp_home(context)
    config = struct!(Configuration, @valid_fields)
    :ok = Configuration.store(config, home)

    pid = start_supervised!({WorkerSupervisor, home: home})

    children = Supervisor.which_children(pid)
    ids = Enum.map(children, fn {id, _child, _type, _modules} -> id end)

    # Task 3 adds `GatewayConnection` as a second, independently-lived child
    # (it dials a real address and is `restart: :temporary`, so it may already
    # have stopped itself by the time this reads the children list); only
    # `State` is asserted present here, matching what
    # `WorkerSupervisor.configuration/1` still relies on.
    assert State in ids
    refute Enum.any?(ids, fn id -> id |> to_string() |> String.contains?("Repo") end)
  end

  describe "agent adapter selection (Task 7)" do
    setup do
      previous_adapter = Application.get_env(:sdd_orchestrator, :agent_adapter)
      previous_executable = Application.get_env(:sdd_orchestrator, :agent_executable)

      on_exit(fn ->
        Application.put_env(:sdd_orchestrator, :agent_adapter, previous_adapter)
        Application.put_env(:sdd_orchestrator, :agent_executable, previous_executable)
      end)

      :ok
    end

    test "wires the paired agent adapter and executable into application env", context do
      home = tmp_home(context)
      config = struct!(Configuration, @valid_fields)
      :ok = Configuration.store(config, home)

      _pid = start_supervised!({WorkerSupervisor, home: home})

      assert Application.get_env(:sdd_orchestrator, :agent_adapter) ==
               SddOrchestrator.Delivery.AgentAdapter.ClaudeCode

      assert Application.get_env(:sdd_orchestrator, :agent_executable) == "/usr/local/bin/claude"
    end

    test "codex is selected the same way", context do
      home = tmp_home(context)
      config = struct!(Configuration, %{@valid_fields | agent_adapter: "codex"})
      :ok = Configuration.store(config, home)

      _pid = start_supervised!({WorkerSupervisor, home: home})

      assert Application.get_env(:sdd_orchestrator, :agent_adapter) ==
               SddOrchestrator.Delivery.AgentAdapter.Codex
    end

    test "an unrecognized agent adapter string falls back to the unavailable default", context do
      home = tmp_home(context)
      config = struct!(Configuration, %{@valid_fields | agent_adapter: "something_else"})
      :ok = Configuration.store(config, home)

      _pid = start_supervised!({WorkerSupervisor, home: home})

      assert Application.get_env(:sdd_orchestrator, :agent_adapter) ==
               SddOrchestrator.Delivery.AgentAdapter.Unavailable
    end
  end
end
