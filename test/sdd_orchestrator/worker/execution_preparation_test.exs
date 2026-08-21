defmodule SddOrchestrator.Worker.ExecutionPreparationEnvelopeSource do
  @moduledoc """
  Supplies the protocol envelope a durable command is delivered as, scoped to
  `SddOrchestrator.Worker.ExecutionPreparationTest`.

  Defined locally (mirroring `SddOrchestrator.Worker.CommandHandlingEnvelopeSource`
  in `command_handling_test.exs`) so this file's `mix test` invocation never
  depends on another test file being compiled alongside it.
  """
  @behaviour SddOrchestrator.Delivery.CommandTransport.EnvelopeSource

  @key {__MODULE__, :envelopes}

  def install do
    original = Application.get_env(:sdd_orchestrator, :command_envelope_source)
    Application.put_env(:sdd_orchestrator, :command_envelope_source, __MODULE__)
    Process.put(@key, %{})

    fn -> Application.put_env(:sdd_orchestrator, :command_envelope_source, original) end
  end

  def script(command_id, envelope) do
    Process.put(@key, Map.put(Process.get(@key, %{}), command_id, envelope))
    envelope
  end

  @impl true
  def envelope(command) do
    case Map.fetch(Process.get(@key, %{}), command.id) do
      {:ok, envelope} -> {:ok, envelope}
      :error -> {:error, :envelope_unavailable}
    end
  end
end

defmodule SddOrchestrator.Worker.ExecutionPreparationTest do
  @moduledoc """
  Task 5 proof: prepares the isolated workspace and feature branch.

  Covers [AC-08] — a validated start command creates or reuses the run
  workspace and isolated branch at the approved base revision, holds the
  single-process lock, reports the workspace ready, and refuses to proceed
  when the working directory cannot be proven to belong to the run.

  The primary flow runs over the real gateway (real `Bandit`, real
  `SddOrchestratorWeb.WorkerChannel`, real `CommandOutbox`, real
  `SddOrchestrator.Worker.GatewayConnection`), matching the pattern
  `GatewayConnectionTest` and `CommandHandlingTest` already establish, and
  against a real local git fixture repository, matching the pattern
  `SddOrchestrator.Delivery.Worker.IsolationTest`'s "repository fixture"
  block already establishes for the primitives this task composes.
  """

  use SddOrchestrator.DataCase, async: false

  import SddOrchestrator.AccountsFixtures
  import SddOrchestrator.ProjectsFixtures

  alias Phoenix.PubSub
  alias SddOrchestrator.Accounts.DeviceWorkspace
  alias SddOrchestrator.Delivery.CommandOutbox
  alias SddOrchestrator.Delivery.CommandTransport.Channel, as: Transport
  alias SddOrchestrator.Delivery.ExecutionManifest
  alias SddOrchestrator.Delivery.ProtocolCodec
  alias SddOrchestrator.Delivery.Worker.Branch
  alias SddOrchestrator.Delivery.Worker.ProcessLock
  alias SddOrchestrator.Delivery.Worker.Workspace
  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.DeliveryProtocolFixtures
  alias SddOrchestrator.Devices.Pairing
  alias SddOrchestrator.Portability.HostedLocalRepositoryBindings
  alias SddOrchestrator.Projects.Project
  alias SddOrchestrator.Repo
  alias SddOrchestrator.Worker.Configuration
  alias SddOrchestrator.Worker.ExecutionPreparationEnvelopeSource, as: EnvelopeSource
  alias SddOrchestrator.Worker.ExecutionPreparer
  alias SddOrchestrator.Worker.GatewayConnection
  alias SddOrchestrator.Worker.RunState
  alias SddOrchestratorWeb.WorkerChannel

  @target_branch "sdd/feature/ftr-0002/run-0003"

  setup do
    previous = Application.fetch_env(:sdd_orchestrator, :worker_workspace_root)

    root =
      Path.join(System.tmp_dir!(), "sdd-execution-prep-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    Application.put_env(:sdd_orchestrator, :worker_workspace_root, root)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:sdd_orchestrator, :worker_workspace_root, value)
        :error -> Application.delete_env(:sdd_orchestrator, :worker_workspace_root)
      end

      File.rm_rf!(root)
    end)

    on_exit(EnvelopeSource.install())

    bandit =
      start_supervised!(
        {Bandit, plug: SddOrchestratorWeb.Endpoint, scheme: :http, port: 0, startup_log: false}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    %{control_plane_address: "http://127.0.0.1:#{port}"}
  end

  if System.find_executable("git") do
    describe "AC-08: workspace and branch preparation over the real gateway" do
      test "a start command against a real repository creates the workspace, branch, and lock, and emits workspace_ready",
           %{control_plane_address: base} do
        %{project: project, feature: feature, run: run, credential: credential} =
          paired_and_bound_project()

        {command, envelope, revision} = enqueue_start_with_real_repository(project, feature, run)
        EnvelopeSource.script(command.id, envelope)

        :ok = PubSub.subscribe(SddOrchestrator.PubSub, WorkerChannel.topic(project.id))

        home = tmp_home()
        config = build_config(base, credential, project.id)
        {:ok, pid} = GatewayConnection.start_link(config, home: home)
        on_exit(fn -> stop_gateway(pid) end)

        wait_until(fn -> Transport.attached(project.id) != [] end)
        assert Transport.deliver(command) == :ok

        assert_receive {:worker_event, event}, 3_000
        assert event["event_type"] == "workspace_ready"
        assert event["source"] == "worker"
        assert event["sequence"] == 1
        assert event["run_id"] == run.id
        assert event["command_id"] == command.id
        assert event["payload"]["branch"] == @target_branch
        assert event["payload"]["base_revision"] == revision
        assert event["payload"]["reused"] == false

        manifest = envelope_manifest(envelope)
        assert {:ok, directory} = Workspace.working_directory(manifest)
        assert File.dir?(directory)
        assert {:ok, true} = Branch.Repository.Git.branch_exists?(directory, @target_branch)

        assert {:ok, %{current: current}} = RunState.load(home)
        assert current.last_sequence == 1

        # The server-side outbox already answers a redelivery as a duplicate
        # without re-executing (`CommandHandlingTest` proves that at the
        # `CommandHandler` level); this proves the effect one layer up —
        # a redelivered command must not produce a second workspace_ready
        # event either.
        assert Transport.deliver(command) == :ok
        refute_receive {:worker_event, _second}, 300
      end
    end
  else
    test "the real repository proof needs git" do
      flunk("environment blocker: no git executable, so the repository fixture cannot be proven")
    end
  end

  describe "ExecutionPreparer.prepare/2" do
    test "returns a protocol-valid workspace_ready event over a real repository and records sequence 1" do
      home = tmp_home()
      {envelope, revision} = envelope_with_real_repository()
      seed_run_state(home, envelope)

      assert {:ok, event} = ExecutionPreparer.prepare(envelope, home)
      assert ProtocolCodec.validate(event) == :ok
      assert event["event_type"] == "workspace_ready"
      assert event["sequence"] == 1
      assert event["payload"]["base_revision"] == revision

      assert {:ok, %{current: current}} = RunState.load(home)
      assert current.last_sequence == 1
    end

    test "a base revision the repository does not have is refused before any lock is acquired" do
      home = tmp_home()
      envelope = envelope_for_manifest(DeliveryProtocolFixtures.manifest())

      assert {:error, :base_revision_mismatch} = ExecutionPreparer.prepare(envelope, home)

      manifest = envelope_manifest(envelope)
      assert {:ok, workspace} = Workspace.prepare(manifest)
      refute File.exists?(Path.join(workspace, "run.lock"))
    end

    test "the acquired lock is the same already-proven ProcessLock primitive: reclaimable and releasable" do
      home = tmp_home()
      {envelope, _revision} = envelope_with_real_repository()
      seed_run_state(home, envelope)

      assert {:ok, _event} = ExecutionPreparer.prepare(envelope, home)

      manifest = envelope_manifest(envelope)
      fence_token = envelope["fence_token"]

      assert {:ok, reclaimed} = ProcessLock.acquire(manifest, fence_token)
      assert reclaimed.fence_token == fence_token

      assert :ok = ProcessLock.release(reclaimed)
      assert {:ok, workspace} = Workspace.prepare(manifest)
      refute File.exists?(Path.join(workspace, "run.lock"))
    end
  end

  # --- helpers -------------------------------------------------------------

  defp tmp_home do
    dir =
      Path.join(
        System.tmp_dir!(),
        "worker-execution-preparation-test-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp envelope_manifest(envelope) do
    {:ok, manifest} = ProtocolCodec.manifest(envelope)
    manifest
  end

  defp envelope_for_manifest(manifest) do
    DeliveryProtocolFixtures.command(%{
      "attempt_number" => manifest.attempt_number,
      "manifest_digest" => ExecutionManifest.digest(manifest),
      "payload" => %{"manifest" => ExecutionManifest.to_map(manifest)}
    })
  end

  defp seed_run_state(home, envelope) do
    current = %RunState{
      command_id: envelope["command_id"],
      operation: envelope["operation"],
      project_id: envelope["project_id"],
      feature_id: envelope["feature_id"],
      run_id: envelope["run_id"],
      attempt_number: envelope["attempt_number"],
      fence_token: envelope["fence_token"],
      manifest_digest: envelope["manifest_digest"],
      last_sequence: 0,
      agent_thread_ref: nil,
      branch: envelope["payload"]["manifest"]["target_branch"],
      lifecycle: "accepted"
    }

    :ok = RunState.store(%{current: current, previous: nil}, home)
  end

  # A manifest bound to a real, freshly created local git repository at a
  # real resolvable base revision — the same "repository fixture" pattern
  # `SddOrchestrator.Delivery.Worker.IsolationTest` already establishes for
  # `Branch.prepare/2` directly, reused here at the composed level.
  defp envelope_with_real_repository do
    probe = DeliveryProtocolFixtures.manifest()
    {:ok, _workspace} = Workspace.prepare(probe)
    {:ok, directory} = Workspace.working_directory(probe)

    git!(directory, ["init", "--quiet"])
    git!(directory, ["commit", "--allow-empty", "--quiet", "--message", "base"])
    revision = git!(directory, ["rev-parse", "HEAD"])

    manifest = DeliveryProtocolFixtures.manifest(%{"repository_base_revision" => revision})
    {envelope_for_manifest(manifest), revision}
  end

  defp enqueue_start_with_real_repository(project, feature, run) do
    probe =
      DeliveryProtocolFixtures.manifest(%{
        "project_id" => project.id,
        "feature_id" => feature.id,
        "run_id" => run.id
      })

    {:ok, _workspace} = Workspace.prepare(probe)
    {:ok, directory} = Workspace.working_directory(probe)

    git!(directory, ["init", "--quiet"])
    git!(directory, ["commit", "--allow-empty", "--quiet", "--message", "base"])
    revision = git!(directory, ["rev-parse", "HEAD"])

    manifest =
      DeliveryProtocolFixtures.manifest(%{
        "project_id" => project.id,
        "feature_id" => feature.id,
        "run_id" => run.id,
        "repository_base_revision" => revision
      })

    digest = ExecutionManifest.digest(manifest)

    attempt =
      DeliveryFixtures.attempt_fixture(run, %{
        attempt_number: 1,
        fence_token: 1,
        manifest_digest: digest,
        continuation_reason: "initial"
      })

    {:ok, command} =
      CommandOutbox.enqueue(%{
        id: Ecto.UUID.generate(),
        project_id: project.id,
        run_id: run.id,
        attempt_id: attempt.id,
        operation: "start",
        expected_state_version: run.state_version,
        manifest_digest: digest
      })

    envelope =
      DeliveryProtocolFixtures.command(%{
        "command_id" => command.id,
        "project_id" => project.id,
        "feature_id" => feature.id,
        "run_id" => run.id,
        "attempt_number" => 1,
        "fence_token" => 1,
        "expected_state_version" => command.expected_state_version,
        "manifest_digest" => digest,
        "payload" => %{"manifest" => ExecutionManifest.to_map(manifest)}
      })

    {command, envelope, revision}
  end

  defp git!(directory, args) do
    identity = [
      "-c",
      "user.name=SDD Orchestrator Test",
      "-c",
      "user.email=test@example.invalid",
      "-c",
      "commit.gpgsign=false",
      "-c",
      "init.defaultBranch=base"
    ]

    {output, 0} = System.cmd("git", identity ++ args, cd: directory, stderr_to_stdout: true)
    String.trim(output)
  end

  defp build_config(control_plane_address, worker_credential, project_id) do
    %Configuration{
      control_plane_address: control_plane_address,
      device_workspace_id: Ecto.UUID.generate(),
      worker_credential: worker_credential,
      agent_adapter: "claude_code",
      agent_executable: "/usr/local/bin/claude",
      workspace_root: System.tmp_dir!(),
      project_id: project_id,
      worker_id: Ecto.UUID.generate()
    }
  end

  defp stop_gateway(pid) do
    if Process.alive?(pid) do
      Process.unlink(pid)
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      after
        1_000 -> :ok
      end
    end
  end

  defp wait_until(fun, timeout \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition not met within timeout")

      true ->
        Process.sleep(20)
        do_wait_until(fun, deadline)
    end
  end

  defp paired_and_bound_project do
    account = account_fixture()
    personal_workspace = workspace_fixture(account)
    device_workspace = %DeviceWorkspace{id: Ecto.UUID.generate()}
    project = local_project_fixture(personal_workspace, portable_identifier())
    feature = DeliveryFixtures.feature_fixture(project, account)
    run = DeliveryFixtures.run_fixture(project, feature)

    {worker, credential} = available_worker_fixture(device_workspace)

    {:ok, %{binding: binding}} =
      HostedLocalRepositoryBindings.put_validated_binding(
        personal_workspace,
        project.id,
        device_workspace,
        worker.id,
        project.canonical_repository_id
      )

    %{
      project: project,
      feature: feature,
      run: run,
      worker: worker,
      credential: credential,
      device_workspace: device_workspace,
      binding: binding
    }
  end

  defp local_project_fixture(personal_workspace, repository_id) do
    %Project{}
    |> Project.changeset(%{
      name: "local-project-#{System.unique_integer([:positive])}",
      workspace_id: personal_workspace.id,
      storage_mode: "hosted",
      repository_provider: "local",
      canonical_repository_id: repository_id
    })
    |> Repo.insert!()
  end

  defp available_worker_fixture(device_workspace) do
    {worker, credential} = paired_worker_fixture(device_workspace)
    {:ok, worker} = Pairing.mark_seen(worker)
    {worker, credential}
  end

  defp paired_worker_fixture(device_workspace) do
    {:ok, %{code: code}} = Pairing.start_pairing(device_workspace.id)

    {:ok, %{worker: worker, credential: credential}} =
      Pairing.complete_pairing(code, %{
        os_family: "macos",
        os_major: "26",
        app_version: "1.0.0",
        protocol_version: "1"
      })

    {worker, credential}
  end

  defp portable_identifier do
    salt = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    digest = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    "local-repo:v1:#{salt}:#{digest}"
  end
end
