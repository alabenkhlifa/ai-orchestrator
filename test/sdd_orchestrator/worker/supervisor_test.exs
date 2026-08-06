defmodule SddOrchestrator.Worker.SupervisorTest do
  @moduledoc """
  Task 2 proof: `SddOrchestrator.Worker.Supervisor` refuses to start with a
  typed reason on missing or invalid configuration rather than starting
  partially, and, once started with valid configuration, its children never
  include a database repo.
  """

  use ExUnit.Case, async: true

  alias SddOrchestrator.Worker.Configuration
  alias SddOrchestrator.Worker.State
  alias SddOrchestrator.Worker.Supervisor, as: WorkerSupervisor

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

    assert ids == [State]
    refute Enum.any?(ids, fn id -> id |> to_string() |> String.contains?("Repo") end)
  end
end
