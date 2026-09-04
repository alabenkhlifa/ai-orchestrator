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
  alias SddOrchestrator.Worker.GatewayConnection
  alias SddOrchestrator.Worker.ProjectConnections
  alias SddOrchestrator.Worker.RepositoryMetadata
  alias SddOrchestrator.Worker.RepositorySelection
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

  # A worker paired from the app's menu bar: authorized for its Mac, with no
  # project and no repository folder.
  defp mac_only_config,
    do: struct!(Configuration, Map.drop(@valid_fields, [:workspace_root, :project_id]))

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

    # The rule is "no Ecto repo child", so the id is asked whether it names one.
    # A `"Repo"` substring test no longer answers that question: specs/40's
    # `RepositorySelection` child contains the word and is not a database repo.
    refute Enum.any?(ids, fn id -> id |> Module.split() |> List.last() == "Repo" end)
  end

  describe "a worker with no project" do
    setup do
      previous_root = Application.fetch_env(:sdd_orchestrator, :worker_workspace_root)
      previous_adapter = Application.get_env(:sdd_orchestrator, :agent_adapter)
      previous_executable = Application.get_env(:sdd_orchestrator, :agent_executable)

      on_exit(fn ->
        case previous_root do
          {:ok, value} -> Application.put_env(:sdd_orchestrator, :worker_workspace_root, value)
          :error -> Application.delete_env(:sdd_orchestrator, :worker_workspace_root)
        end

        Application.put_env(:sdd_orchestrator, :agent_adapter, previous_adapter)
        Application.put_env(:sdd_orchestrator, :agent_executable, previous_executable)
      end)

      :ok
    end

    test "starts and holds its configuration", context do
      home = tmp_home(context)
      config = mac_only_config()
      :ok = Configuration.store(config, home)

      pid = start_supervised!({WorkerSupervisor, home: home})

      assert WorkerSupervisor.configuration(pid) == config
      assert WorkerSupervisor.configuration(pid).project_id == nil
    end

    # `GatewayConnection` is `restart: :temporary` and dials a real address, so
    # a started one may already have stopped itself before `which_children/1`
    # is read. `init/1` is the one place that answers what the tree starts
    # without that race.
    # Task 1 of specs/39 started `[State]` alone here, because
    # `GatewayConnection` could then only build a project topic. Task 7 taught
    # it the Mac-scoped scope, so withholding it became the very defect the
    # slice exists to close: a paired worker that connects to nothing. A real
    # browser pairing found it, because every other test starts
    # `GatewayConnection` itself and never asks the supervisor.
    # specs/40 Task 3 adds `RepositorySelection` between them: it holds the one
    # open folder-picker request, and it starts before the connection so a
    # request arriving on the first join has somewhere to land.
    # specs/47 Task 5 adds `RepositoryMetadata` right after it, for the same
    # reason: it holds the one open repository-metadata question and calls into
    # `RepositorySelection` for the folder it needs, so it starts after that and
    # still before the connection can deliver a `repository_metadata` message.
    # specs/41 Task 7 adds `ProjectConnections` for the same reason: it holds
    # one connection per project this worker is told to serve, and a
    # `project_bound` notice arriving on the first join has to have somewhere to
    # open.
    test "starts the gateway connection for both scopes" do
      assert {:ok, {_flags, mac_only_children}} = WorkerSupervisor.init(mac_only_config())

      assert Enum.map(mac_only_children, & &1.id) == [
               State,
               RepositorySelection,
               RepositoryMetadata,
               ProjectConnections,
               GatewayConnection
             ]

      assert {:ok, {_flags, project_children}} =
               WorkerSupervisor.init(struct!(Configuration, @valid_fields))

      assert Enum.map(project_children, & &1.id) == [
               State,
               RepositorySelection,
               RepositoryMetadata,
               ProjectConnections,
               GatewayConnection
             ]
    end

    test "leaves the workspace root unset instead of configuring a nil one", context do
      home = tmp_home(context)
      :ok = Configuration.store(mac_only_config(), home)
      Application.put_env(:sdd_orchestrator, :worker_workspace_root, "/left/over/from/before")

      _pid = start_supervised!({WorkerSupervisor, home: home})

      assert Application.fetch_env(:sdd_orchestrator, :worker_workspace_root) == :error
    end

    test "still wires the paired agent adapter and executable", context do
      home = tmp_home(context)
      :ok = Configuration.store(mac_only_config(), home)

      _pid = start_supervised!({WorkerSupervisor, home: home})

      assert Application.get_env(:sdd_orchestrator, :agent_adapter) ==
               SddOrchestrator.Delivery.AgentAdapter.ClaudeCode

      assert Application.get_env(:sdd_orchestrator, :agent_executable) == "/usr/local/bin/claude"
    end
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
