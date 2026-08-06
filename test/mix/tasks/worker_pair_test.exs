defmodule Mix.Tasks.Worker.PairTest do
  @moduledoc """
  Task 2 proof: the `mix worker.pair` CLI surface — required options, agent
  validation, a failed pairing writing nothing, and a successful pairing
  storing the worker configuration and printing a credential-free
  confirmation.
  """

  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Devices.Pairing
  alias SddOrchestrator.Worker.Configuration

  setup do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Mix.shell(previous_shell)
    end)

    :ok
  end

  defp tmp_home do
    dir =
      Path.join(System.tmp_dir!(), "worker-pair-cli-test-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp valid_code do
    {:ok, %{code: code}} = Pairing.start_pairing(Ecto.UUID.generate())
    code
  end

  defp base_argv(home, code) do
    [
      "--code",
      code,
      "--control-plane",
      "http://localhost:4000",
      "--agent",
      "claude_code",
      "--agent-executable",
      "/usr/local/bin/claude",
      "--workspace-root",
      "/Users/dev/project",
      "--home",
      home
    ]
  end

  test "requires --code" do
    argv = [
      "--control-plane",
      "x",
      "--agent",
      "claude_code",
      "--agent-executable",
      "x",
      "--workspace-root",
      "x"
    ]

    assert_raise Mix.Error, ~r/--code/, fn -> Mix.Tasks.Worker.Pair.run(argv) end
  end

  test "requires --control-plane" do
    argv = [
      "--code",
      "x",
      "--agent",
      "claude_code",
      "--agent-executable",
      "x",
      "--workspace-root",
      "x"
    ]

    assert_raise Mix.Error, ~r/--control-plane/, fn -> Mix.Tasks.Worker.Pair.run(argv) end
  end

  test "rejects an --agent value that is not claude_code or codex" do
    home = tmp_home()
    argv = base_argv(home, valid_code()) |> replace("--agent", "not_a_real_agent")

    assert_raise Mix.Error, ~r/claude_code, codex/, fn -> Mix.Tasks.Worker.Pair.run(argv) end
    assert {:error, :not_paired} = Configuration.load(home)
  end

  test "an invalid pairing code raises and writes no configuration file" do
    home = tmp_home()
    argv = base_argv(home, "not-a-real-code")

    assert_raise Mix.Error, ~r/pairing failed/, fn -> Mix.Tasks.Worker.Pair.run(argv) end
    assert {:error, :not_paired} = Configuration.load(home)
  end

  test "a successful pairing stores the configuration and prints a credential-free confirmation" do
    home = tmp_home()
    argv = base_argv(home, valid_code())

    Mix.Tasks.Worker.Pair.run(argv)

    assert {:ok, config} = Configuration.load(home)
    assert config.control_plane_address == "http://localhost:4000"
    assert config.agent_adapter == "claude_code"
    assert config.agent_executable == "/usr/local/bin/claude"
    assert config.workspace_root == "/Users/dev/project"
    assert is_binary(config.worker_credential)
    assert is_binary(config.device_workspace_id)

    assert File.stat!(home).mode |> Bitwise.band(0o777) == 0o700
    assert File.stat!(Configuration.path(home)).mode |> Bitwise.band(0o777) == 0o600

    printed =
      Stream.repeatedly(fn ->
        receive do
          {:mix_shell, :info, [msg]} -> msg
        after
          0 -> nil
        end
      end)
      |> Enum.take_while(&(&1 != nil))
      |> Enum.join("\n")

    refute printed =~ config.worker_credential
  end

  defp replace(argv, flag, value) do
    index = Enum.find_index(argv, &(&1 == flag))
    List.replace_at(argv, index + 1, value)
  end
end
