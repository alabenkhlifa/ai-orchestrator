defmodule SddOrchestrator.Worker.ConfigurationTest do
  @moduledoc """
  Task 2 proof: worker-local configuration storage, home-directory
  resolution, owner-only permissions, and typed startup refusal — all
  without touching the database. Real pairing-backed round trips live in
  `SddOrchestrator.Worker.PairingTest`.
  """

  # Mutates the `:worker_home` application env, which is global state.
  use ExUnit.Case, async: false

  alias SddOrchestrator.Worker.Configuration

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

  defp valid_config, do: struct!(Configuration, @valid_fields)

  defp tmp_home(context) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "worker-config-test-#{context.test}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  describe "home/1 resolution" do
    test "an explicit override wins" do
      assert Configuration.home("/explicit/override") == "/explicit/override"
    end

    test "falls back to the :worker_home application env when no override is given" do
      previous = Application.get_env(:sdd_orchestrator, :worker_home)
      Application.put_env(:sdd_orchestrator, :worker_home, "/tmp/worker-home-env")

      on_exit(fn ->
        if previous do
          Application.put_env(:sdd_orchestrator, :worker_home, previous)
        else
          Application.delete_env(:sdd_orchestrator, :worker_home)
        end
      end)

      assert Configuration.home(nil) == "/tmp/worker-home-env"
    end

    test "falls back to ~/.sdd_orchestrator/worker when nothing else is set" do
      previous = Application.get_env(:sdd_orchestrator, :worker_home)
      Application.delete_env(:sdd_orchestrator, :worker_home)

      on_exit(fn ->
        previous && Application.put_env(:sdd_orchestrator, :worker_home, previous)
      end)

      assert Configuration.home(nil) == Path.join(System.user_home!(), ".sdd_orchestrator/worker")
    end
  end

  describe "store/2 and load/1 round trip" do
    test "storing then loading reproduces the same configuration", context do
      home = tmp_home(context)
      config = valid_config()

      assert :ok = Configuration.store(config, home)
      assert {:ok, loaded} = Configuration.load(home)
      assert loaded == config
    end

    test "the directory and file are created owner-only (0700 / 0600)", context do
      home = tmp_home(context)
      :ok = Configuration.store(valid_config(), home)

      dir_mode = File.stat!(home).mode |> Bitwise.band(0o777)
      file_mode = File.stat!(Configuration.path(home)).mode |> Bitwise.band(0o777)

      assert dir_mode == 0o700
      assert file_mode == 0o600
    end

    test "restarting reuses the stored credential without a new pairing code", context do
      home = tmp_home(context)
      config = valid_config()
      :ok = Configuration.store(config, home)

      assert {:ok, first_load} = Configuration.load(home)
      assert {:ok, second_load} = Configuration.load(home)

      assert first_load == config
      assert second_load == config
      assert first_load.worker_credential == config.worker_credential
    end
  end

  describe "load/1 typed refusal" do
    test "a fresh, never-paired home returns {:error, :not_paired}", context do
      home = tmp_home(context)
      refute File.exists?(home)

      assert {:error, :not_paired} = Configuration.load(home)
    end

    test "malformed JSON returns a typed invalid_configuration error, not a crash", context do
      home = tmp_home(context)
      File.mkdir_p!(home)
      File.write!(Configuration.path(home), "{not valid json")

      assert {:error, {:invalid_configuration, _reason}} = Configuration.load(home)
    end

    test "valid JSON missing a required field returns a typed invalid_configuration error",
         context do
      home = tmp_home(context)
      File.mkdir_p!(home)

      incomplete =
        @valid_fields
        |> Map.delete(:worker_credential)
        |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)

      File.write!(Configuration.path(home), Jason.encode!(incomplete))

      assert {:error, {:invalid_configuration, {:missing_field, "worker_credential"}}} =
               Configuration.load(home)
    end

    test "a blank required field is treated the same as missing", context do
      home = tmp_home(context)
      File.mkdir_p!(home)

      fields =
        @valid_fields
        |> Map.put(:agent_executable, "   ")
        |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)

      File.write!(Configuration.path(home), Jason.encode!(fields))

      assert {:error, {:invalid_configuration, {:missing_field, "agent_executable"}}} =
               Configuration.load(home)
    end
  end
end
