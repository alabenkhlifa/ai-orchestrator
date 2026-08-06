defmodule SddOrchestrator.Worker.PairingTest do
  @moduledoc """
  Task 2 proof: completing a real, database-backed pairing (via
  `SddOrchestrator.Devices.Pairing`, exactly like the local-onboarding UI
  stub does) and turning the result into a stored, worker-local
  `SddOrchestrator.Worker.Configuration` — under a temp home directory, never
  the developer's real one, and never anywhere else in the project tree.
  """

  use SddOrchestrator.DataCase, async: true

  alias SddOrchestrator.Devices.Pairing
  alias SddOrchestrator.Worker.Configuration

  @cli_fields %{
    control_plane_address: "http://localhost:4000",
    agent_adapter: "claude_code",
    agent_executable: "/usr/local/bin/claude",
    workspace_root: "/Users/dev/project"
  }

  defp tmp_home do
    dir =
      Path.join(System.tmp_dir!(), "worker-pairing-test-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp paired(workspace_id \\ Ecto.UUID.generate()) do
    {:ok, %{code: code}} = Pairing.start_pairing(workspace_id)

    {:ok, pairing_result} =
      Pairing.complete_pairing(code, %{
        os_family: "macos",
        os_major: "15",
        app_version: "1.0.0",
        protocol_version: "1"
      })

    pairing_result
  end

  test "completing pairing stores the credential and configuration worker-locally" do
    home = tmp_home()
    pairing_result = paired()

    config = Configuration.from_pairing(pairing_result, @cli_fields)
    assert :ok = Configuration.store(config, home)

    assert {:ok, loaded} = Configuration.load(home)
    assert loaded.worker_credential == pairing_result.credential
    assert loaded.device_workspace_id == pairing_result.worker.device_workspace_id
    assert loaded.control_plane_address == @cli_fields.control_plane_address
    assert loaded.agent_adapter == @cli_fields.agent_adapter
    assert loaded.agent_executable == @cli_fields.agent_executable
    assert loaded.workspace_root == @cli_fields.workspace_root
  end

  test "the stored directory and file are owner-only" do
    home = tmp_home()
    config = Configuration.from_pairing(paired(), @cli_fields)
    :ok = Configuration.store(config, home)

    assert File.stat!(home).mode |> Bitwise.band(0o777) == 0o700
    assert File.stat!(Configuration.path(home)).mode |> Bitwise.band(0o777) == 0o600
  end

  test "restarting (reloading) reuses the stored credential without a new pairing code" do
    home = tmp_home()
    pairing_result = paired()
    config = Configuration.from_pairing(pairing_result, @cli_fields)
    :ok = Configuration.store(config, home)

    assert {:ok, first} = Configuration.load(home)
    assert {:ok, second} = Configuration.load(home)

    assert first.worker_credential == pairing_result.credential
    assert second.worker_credential == pairing_result.credential
  end

  test "pairing writes the credential nowhere except the one owner-only file" do
    project_root = File.cwd!()
    before = System.cmd("git", ["status", "--porcelain"], cd: project_root)

    home = tmp_home()
    config = Configuration.from_pairing(paired(), @cli_fields)
    :ok = Configuration.store(config, home)

    aftr = System.cmd("git", ["status", "--porcelain"], cd: project_root)

    assert before == aftr
    refute File.exists?(Path.join(project_root, "worker.json"))
  end

  test "the pair task's confirmation output never includes the raw credential" do
    pairing_result = paired()

    output = Mix.Tasks.Worker.Pair.confirmation(pairing_result)

    refute output =~ pairing_result.credential
    assert output =~ pairing_result.worker.id
  end
end
