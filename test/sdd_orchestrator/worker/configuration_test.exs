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

  @project_fields [:workspace_root, :project_id]

  # What the app's menu-bar pairing supplies: no project, no repository folder.
  @mac_only_cli_fields %{
    control_plane_address: "http://localhost:4000",
    agent_adapter: "claude_code",
    agent_executable: "/usr/local/bin/claude"
  }

  defp valid_config, do: struct!(Configuration, @valid_fields)

  # A worker paired from the app's menu bar: authorized for its Mac, with no
  # project and no repository folder.
  defp mac_only_config, do: struct!(Configuration, Map.drop(@valid_fields, @project_fields))

  defp stored_json(home) do
    home |> Configuration.path() |> File.read!() |> Jason.decode!()
  end

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

  describe "a worker authorized for its Mac alone" do
    test "builds from pairing with no project and no repository folder" do
      pairing_result = pairing_result()

      config = Configuration.from_pairing(pairing_result, @mac_only_cli_fields)

      assert config.project_id == nil
      assert config.workspace_root == nil
      assert config.worker_id == pairing_result.worker.id
      assert config.worker_credential == pairing_result.credential
    end

    test "a field a worker cannot run without is still not optional" do
      # Dropped at runtime rather than written as a short literal so the
      # compiler's type checker does not report the deliberate omission this
      # test exists to prove is refused.
      without_executable = Map.drop(@mac_only_cli_fields, [:agent_executable])

      assert_raise KeyError, fn ->
        Configuration.from_pairing(pairing_result(), without_executable)
      end
    end

    test "stores and loads back unchanged", context do
      home = tmp_home(context)
      config = mac_only_config()

      assert :ok = Configuration.store(config, home)
      assert {:ok, loaded} = Configuration.load(home)

      assert loaded == config
      assert loaded.project_id == nil
      assert loaded.workspace_root == nil
      assert loaded.worker_credential == config.worker_credential
    end

    test "the stored file records no project rather than an empty one", context do
      home = tmp_home(context)
      :ok = Configuration.store(mac_only_config(), home)

      decoded = stored_json(home)

      refute Map.has_key?(decoded, "project_id")
      refute Map.has_key?(decoded, "workspace_root")
      assert decoded["worker_id"] == @valid_fields.worker_id
    end

    test "a file carrying both keys as null loads as a worker with neither", context do
      home = tmp_home(context)
      File.mkdir_p!(home)

      fields =
        @valid_fields
        |> Map.merge(%{workspace_root: nil, project_id: nil})
        |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)

      File.write!(Configuration.path(home), Jason.encode!(fields))

      assert {:ok, loaded} = Configuration.load(home)
      assert loaded == mac_only_config()
    end
  end

  describe "a configuration written before the project became optional" do
    test "loads with its project and repository folder intact", context do
      home = tmp_home(context)
      File.mkdir_p!(home)

      # The old on-disk shape: every field present, written directly rather
      # than through `store/2`, so this proves the decode path against a file
      # this version would no longer write.
      old_shape = Map.new(@valid_fields, fn {k, v} -> {Atom.to_string(k), v} end)
      File.write!(Configuration.path(home), Jason.encode!(old_shape))

      assert {:ok, loaded} = Configuration.load(home)

      assert loaded == valid_config()
      assert loaded.project_id == @valid_fields.project_id
      assert loaded.workspace_root == @valid_fields.workspace_root
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

    # The project and the repository folder became optional; nothing else did.
    # Each remaining required field is asserted individually so dropping one
    # from the enforced set can never pass unnoticed.
    for field <- Map.keys(@valid_fields) -- @project_fields do
      test "an absent #{field} is still refused", context do
        home = tmp_home(context)
        File.mkdir_p!(home)

        fields =
          @valid_fields
          |> Map.drop(@project_fields ++ [unquote(field)])
          |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)

        File.write!(Configuration.path(home), Jason.encode!(fields))

        assert {:error, {:invalid_configuration, {:missing_field, unquote(to_string(field))}}} =
                 Configuration.load(home)
      end
    end
  end

  describe "agent adapters" do
    # An adapter string outside this set is refused where it is chosen — the
    # `mix worker.pair` CLI checks it against this list before pairing, and
    # `Worker.Supervisor` falls back to the unavailable adapter for anything
    # it does not recognize. `load/1` deliberately does not re-refuse it; this
    # asserts the allowed set itself did not widen.
    test "the allowed set is unchanged" do
      assert Configuration.agent_adapters() == ~w(claude_code codex)
    end

    test "a blank agent adapter is refused at load", context do
      home = tmp_home(context)
      File.mkdir_p!(home)

      fields =
        @valid_fields
        |> Map.put(:agent_adapter, "")
        |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)

      File.write!(Configuration.path(home), Jason.encode!(fields))

      assert {:error, {:invalid_configuration, {:missing_field, "agent_adapter"}}} =
               Configuration.load(home)
    end
  end

  defp pairing_result do
    %{
      worker: %{id: Ecto.UUID.generate(), device_workspace_id: Ecto.UUID.generate()},
      credential: "worker-credential-secret"
    }
  end
end
