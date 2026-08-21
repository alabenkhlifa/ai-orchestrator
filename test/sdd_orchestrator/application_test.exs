defmodule SddOrchestrator.ApplicationTest do
  @moduledoc """
  specs/36-local-worker-native-distribution Task 1 proof.

  Exercises `SddOrchestrator.Application`'s worker-mode boot logic in
  isolation from the real, already-running top-level OTP application (which
  already owns the `SddOrchestrator.Supervisor` name in this test run) —
  each test starts its own differently-named `DynamicSupervisor` host and
  drives `worker_mode_children/0`/`attach_paired_worker/1` directly, the
  same functions `start/2`'s worker-mode branch calls.
  """

  # Mutates the `SDD_ORCHESTRATOR_RELEASE_MODE` OS env var and the shared
  # `:worker_home` application env, the same global state
  # `Configuration`/`WorkerSupervisor` tests mutate elsewhere.
  use ExUnit.Case, async: false

  alias SddOrchestrator.Application, as: App
  alias SddOrchestrator.Worker.Configuration
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
        "application-worker-mode-test-#{context.test}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp put_worker_home(home) do
    previous = Application.get_env(:sdd_orchestrator, :worker_home)
    Application.put_env(:sdd_orchestrator, :worker_home, home)

    on_exit(fn ->
      if previous do
        Application.put_env(:sdd_orchestrator, :worker_home, previous)
      else
        Application.delete_env(:sdd_orchestrator, :worker_home)
      end
    end)
  end

  describe "boot_mode/0" do
    test "defaults to :control_plane when SDD_ORCHESTRATOR_RELEASE_MODE is unset" do
      previous = System.get_env("SDD_ORCHESTRATOR_RELEASE_MODE")
      System.delete_env("SDD_ORCHESTRATOR_RELEASE_MODE")
      on_exit(fn -> previous && System.put_env("SDD_ORCHESTRATOR_RELEASE_MODE", previous) end)

      assert App.boot_mode() == :control_plane
    end

    test "reads :worker only from the exact release-mode value" do
      previous = System.get_env("SDD_ORCHESTRATOR_RELEASE_MODE")

      on_exit(fn ->
        if previous do
          System.put_env("SDD_ORCHESTRATOR_RELEASE_MODE", previous)
        else
          System.delete_env("SDD_ORCHESTRATOR_RELEASE_MODE")
        end
      end)

      System.put_env("SDD_ORCHESTRATOR_RELEASE_MODE", "worker")
      assert App.boot_mode() == :worker

      System.put_env("SDD_ORCHESTRATOR_RELEASE_MODE", "something_else")
      assert App.boot_mode() == :control_plane
    end
  end

  describe "worker_mode_children/0" do
    test "is a single DynamicSupervisor host, registered as worker_host_name/0" do
      assert [{DynamicSupervisor, opts}] = App.worker_mode_children()
      assert Keyword.fetch!(opts, :name) == App.worker_host_name()
      assert Keyword.fetch!(opts, :strategy) == :one_for_one
    end
  end

  describe "worker-mode boot with no stored configuration" do
    test "the host starts successfully, empty, with no crash", context do
      put_worker_home(tmp_home(context))

      [{DynamicSupervisor, host_opts}] = App.worker_mode_children()
      host_name = :"worker_host_#{context.test}"

      pid = start_supervised!({DynamicSupervisor, Keyword.put(host_opts, :name, host_name)})
      assert Process.alive?(pid)

      assert DynamicSupervisor.count_children(host_name) == %{
               active: 0,
               specs: 0,
               supervisors: 0,
               workers: 0
             }

      assert App.attach_paired_worker(host_name) == :ok

      # `worker_mode_children/0` is asserted above to be exactly the one
      # `DynamicSupervisor` entry — never `Endpoint`/`Repo`/`Vault` — so
      # this test only needs to confirm that host boots empty and clean.
      assert DynamicSupervisor.count_children(host_name).active == 0
    end
  end

  describe "worker-mode boot with an already-stored configuration" do
    test "attaches Worker.Supervisor under the host right away", context do
      home = tmp_home(context)
      config = struct!(Configuration, @valid_fields)
      :ok = Configuration.store(config, home)
      put_worker_home(home)

      [{DynamicSupervisor, host_opts}] = App.worker_mode_children()
      host_name = :"worker_host_#{context.test}"

      _pid = start_supervised!({DynamicSupervisor, Keyword.put(host_opts, :name, host_name)})

      assert {:ok, worker_pid} = App.attach_paired_worker(host_name)
      assert Process.alive?(worker_pid)
      assert DynamicSupervisor.count_children(host_name).active == 1
      assert WorkerSupervisor.configuration(worker_pid) == config
    end
  end
end
