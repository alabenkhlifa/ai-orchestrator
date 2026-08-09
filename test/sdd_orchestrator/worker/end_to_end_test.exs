defmodule SddOrchestrator.Worker.EndToEndEnvelopeSource do
  @moduledoc """
  Supplies the protocol envelope a durable command is delivered as, scoped to
  `SddOrchestrator.Worker.EndToEndTest`.

  Mirrors the pattern every other worker integration test file already
  establishes (`CommandLifecycleEnvelopeSource`, `RequiredCheckRunnerEnvelopeSource`,
  and their siblings), defined locally so this file's `mix test` invocation
  never depends on another test file being compiled alongside it.
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

defmodule SddOrchestrator.Worker.EndToEndTest do
  @moduledoc """
  Task 12 proof: one real run end to end on a local repository.

  Covers [AC-16] — the whole path the earlier eleven tasks each proved one
  piece of, in one scenario: pair through the real `mix worker.pair` CLI
  entry point, start the worker's real supervision tree through the real
  `mix worker.start` seam, connect and join the real gateway, deliver a real
  `start` command against a real local git fixture repository, let a
  scripted ("recorded") agent stand in for a real coding-agent CLI, observe
  its progress and clean exit, run the attempt's real required check,
  upload its evidence artifact, and reach `verification_completed` — then
  confirm the isolated branch carries the expected state, no other branch
  moved, and nothing delivered to the control plane leaked a credential, an
  absolute path, or raw agent/file content outside the approved contract.

  Runs the full scenario twice, once per configured coding agent
  (`claude_code` and `codex`), which is what the slice verification gate's
  own "with each supported coding agent" line requires beyond this task's
  own narrower proof text.

  Reuses the established real-`Bandit`, real-`GatewayConnection`, real-channel
  harness pattern (`CommandLifecycleTest`, `RequiredCheckRunnerTest`,
  `ExecutionPreparationTest`) rather than inventing new test infrastructure —
  the only new composition here is driving pairing and worker startup
  through their own real CLI entry points (`Mix.Tasks.Worker.Pair.run/1`,
  `Mix.Tasks.Worker.Start.start/1`) instead of hand-built configuration.
  """

  use SddOrchestrator.DataCase, async: false

  import SddOrchestrator.AccountsFixtures
  import SddOrchestrator.ProjectsFixtures

  alias Phoenix.PubSub
  alias SddOrchestrator.ClaudeCodeCliFixture
  alias SddOrchestrator.CodexCliFixture
  alias SddOrchestrator.Delivery.ArtifactStore
  alias SddOrchestrator.Delivery.CommandOutbox
  alias SddOrchestrator.Delivery.CommandTransport.Channel, as: Transport
  alias SddOrchestrator.Delivery.ExecutionManifest
  alias SddOrchestrator.Delivery.LocalWorkerRunGovernance
  alias SddOrchestrator.Delivery.Worker.Branch
  alias SddOrchestrator.Delivery.Worker.Workspace
  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.DeliveryProtocolFixtures
  alias SddOrchestrator.Devices.{LocalWorker, Pairing}
  alias SddOrchestrator.Portability.HostedLocalRepositoryBindings
  alias SddOrchestrator.Projects.Project
  alias SddOrchestrator.Repo
  alias SddOrchestrator.Worker.Configuration
  alias SddOrchestrator.Worker.EndToEndEnvelopeSource, as: EnvelopeSource
  alias SddOrchestrator.Worker.GatewayConnection
  alias SddOrchestrator.Worker.RunState
  alias SddOrchestratorWeb.WorkerChannel

  # Fast, real, and deterministic against the fixture repository itself
  # (never `mix test`/`mix format`, which would depend on this repository's
  # own state) — and its own stdout (the resolved commit SHA) is genuinely
  # non-empty, so this single check both keeps the scenario fast and
  # exercises Task 10's real artifact-upload path rather than being silently
  # skipped by the `:empty_artifact` refusal an empty-output check would hit.
  @required_checks [%{"name" => "revision", "command" => "git rev-parse HEAD"}]

  setup do
    previous_root = Application.fetch_env(:sdd_orchestrator, :worker_workspace_root)
    previous_home = Application.fetch_env(:sdd_orchestrator, :worker_home)
    previous_adapter = Application.fetch_env(:sdd_orchestrator, :agent_adapter)
    previous_executable = Application.fetch_env(:sdd_orchestrator, :agent_executable)
    previous_shell = Mix.shell()

    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      restore_env(:worker_workspace_root, previous_root)
      restore_env(:worker_home, previous_home)
      restore_env(:agent_adapter, previous_adapter)
      restore_env(:agent_executable, previous_executable)
      Mix.shell(previous_shell)
    end)

    on_exit(EnvelopeSource.install())

    bandit =
      start_supervised!(
        {Bandit, plug: SddOrchestratorWeb.Endpoint, scheme: :http, port: 0, startup_log: false}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    %{control_plane_address: "http://127.0.0.1:#{port}"}
  end

  describe "AC-16: one real run end to end on a local repository, with each supported coding agent" do
    test "a complete attempt runs end to end through the real CLI with the claude_code agent",
         %{control_plane_address: base} do
      run_end_to_end_scenario(
        base,
        "claude_code",
        ClaudeCodeCliFixture.streaming_script(claude_clean_exit_lines())
      )
    end

    test "a complete attempt runs end to end through the real CLI with the codex agent",
         %{control_plane_address: base} do
      run_end_to_end_scenario(
        base,
        "codex",
        CodexCliFixture.streaming_script(codex_clean_exit_lines())
      )
    end
  end

  # --- the shared scenario ----------------------------------------------------

  defp run_end_to_end_scenario(base, agent, executable) do
    account = account_fixture()
    personal_workspace = workspace_fixture(account)
    device_workspace = device_workspace_fixture()
    project = local_project_fixture(personal_workspace, portable_identifier())
    feature = DeliveryFixtures.feature_fixture(project, account)
    run = DeliveryFixtures.run_fixture(project, feature)

    workspace_root = unique_tmp_dir("workspace-root")
    home = unique_tmp_dir("home")

    # `WorkerSupervisor.init/1` sets `:worker_workspace_root` itself from the
    # paired configuration once `mix worker.start` runs, but *this* test
    # process also needs it set beforehand to seed the real git fixture
    # repository through the same `Workspace.prepare/1` primitive the worker
    # itself uses. `:worker_home` is the seam `Configuration.home/1` and
    # `RunState`'s own home resolution document as "set by tests" — needed
    # because the supervisor starts `GatewayConnection` with no `:home` opt
    # of its own, so its internal run-state I/O resolves through this
    # application env rather than the `--home` CLI flag directly.
    Application.put_env(:sdd_orchestrator, :worker_workspace_root, workspace_root)
    Application.put_env(:sdd_orchestrator, :worker_home, home)

    {:ok, %{code: code}} = Pairing.start_pairing(device_workspace.id)

    pair_argv = [
      "--code",
      code,
      "--control-plane",
      base,
      "--agent",
      agent,
      "--agent-executable",
      executable,
      "--workspace-root",
      workspace_root,
      "--project",
      project.id,
      "--home",
      home
    ]

    Mix.Tasks.Worker.Pair.run(pair_argv)
    drain_mix_shell()

    assert {:ok, config} = Configuration.load(home)
    assert config.project_id == project.id
    assert config.agent_adapter == agent
    assert config.agent_executable == executable

    worker = Repo.get!(LocalWorker, config.worker_id)
    {:ok, worker} = Pairing.mark_seen(worker)

    assert {:ok, %{binding: _binding}} =
             HostedLocalRepositoryBindings.put_validated_binding(
               personal_workspace,
               project.id,
               device_workspace,
               worker.id,
               project.canonical_repository_id
             )

    {revision, directory, default_branch, default_branch_sha_before} =
      init_repository(project, feature, run)

    manifest =
      DeliveryProtocolFixtures.manifest(%{
        "project_id" => project.id,
        "feature_id" => feature.id,
        "run_id" => run.id,
        "attempt_number" => 1,
        "repository_base_revision" => revision,
        "continuation" => %{"reason" => "initial", "prior_attempt_number" => nil},
        "required_checks" => @required_checks
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

    EnvelopeSource.script(command.id, envelope)

    :ok = PubSub.subscribe(SddOrchestrator.PubSub, WorkerChannel.topic(project.id))

    assert {:ok, supervisor_pid} = Mix.Tasks.Worker.Start.start(["--home", home])
    on_exit(fn -> stop_worker(supervisor_pid) end)

    wait_until(fn -> Transport.attached(project.id) != [] end)

    gateway_pid = gateway_connection_pid(supervisor_pid)
    assert is_pid(gateway_pid)

    socket = :sys.get_state(gateway_pid)
    gateway_token = socket.assigns.gateway_credential
    assert is_binary(gateway_token)

    assert Transport.deliver(command) == :ok

    assert_receive {:worker_event, %{"event_type" => "workspace_ready"} = ready_event}, 5_000
    assert ready_event["payload"]["branch"] == manifest.target_branch
    assert ready_event["payload"]["base_revision"] == revision
    assert ready_event["payload"]["reused"] == false

    assert_receive {:worker_heartbeat, %{"state" => "running"} = heartbeat_running}, 5_000

    assert_receive {:worker_event, %{"event_type" => "progress"} = progress_event}, 5_000
    assert is_binary(progress_event["payload"]["summary"])
    assert progress_event["payload"]["summary"] != ""

    assert_receive {:worker_event,
                    %{
                      "event_type" => "evidence",
                      "source" => "check",
                      "payload" =>
                        %{
                          "name" => "revision",
                          "outcome" => "passed",
                          "command" => "git rev-parse HEAD",
                          "exit_code" => 0
                        } = evidence_payload
                    } = evidence_event},
                   5_000

    assert is_binary(evidence_payload["artifact_ref"])

    assert {:ok, artifact} =
             ArtifactStore.fetch(personal_workspace, project.id, evidence_payload["artifact_ref"])

    assert String.trim(artifact.content) == revision
    assert artifact.digest == evidence_payload["digest"]

    assert_receive {:worker_event,
                    %{"event_type" => "verification_completed", "source" => "worker"} =
                      completion_event},
                   5_000

    assert completion_event["payload"]["branch"] == manifest.target_branch
    assert completion_event["payload"]["revision_id"] == manifest.effective_revision_id
    assert completion_event["payload"]["commit_sha"] == revision

    assert_receive {:worker_heartbeat, %{"state" => "stopping"} = heartbeat_stopping}, 5_000

    wait_until(fn ->
      match?({:ok, %{current: %{lifecycle: "verification_completed"}}}, RunState.load(home))
    end)

    assert {:ok, workspace} = Workspace.prepare(manifest)
    refute File.exists?(Path.join(workspace, "run.lock"))

    # The isolated branch exists at exactly the base revision the recorded
    # agent (a scripted stand-in, not a real code-writing process) left
    # untouched, and the repository's own default branch — present before
    # the run — sits at the exact same commit it started at.
    assert {:ok, true} = Branch.Repository.Git.branch_exists?(directory, manifest.target_branch)
    target_sha = git!(directory, ["rev-parse", manifest.target_branch])
    assert target_sha == revision

    default_branch_sha_after = git!(directory, ["rev-parse", default_branch])
    assert default_branch_sha_after == default_branch_sha_before

    assert {:ok, recorded} = CommandOutbox.fetch(command.id)

    # specs/34-local-worker-runtime-governance (AC-08): this scenario never
    # selects or pins a personal AI connection, so it must produce no
    # `LocalWorkerRunGovernance` row — "ungoverned" asserted positively here,
    # not merely inferred from the row never being mentioned.
    refute LocalWorkerRunGovernance.for_run(run.id)

    refute_boundary_leaks(
      [
        ready_event,
        heartbeat_running,
        progress_event,
        evidence_event,
        completion_event,
        heartbeat_stopping,
        recorded.result
      ],
      [config.worker_credential, gateway_token, directory, workspace_root, home]
    )
  end

  # --- boundary proof ----------------------------------------------------------

  # One reusable check over everything the whole scenario pushed to the
  # channel (every collected event, heartbeat, and the acknowledgement's own
  # recorded result): none of it may contain the worker's real gateway
  # credential or per-connection token, or the fixture repository's real
  # absolute filesystem path (the working directory, the configured
  # workspace root, or the worker's own home directory). Encoding the whole
  # collected list once and scanning for each forbidden substring is one
  # deliberate boundary proof rather than scattered ad hoc assertions.
  defp refute_boundary_leaks(collected, forbidden) do
    encoded = Jason.encode!(collected)

    Enum.each(forbidden, fn value ->
      refute String.contains?(encoded, value),
             "boundary leak: found #{inspect(value)} in worker traffic delivered to the control plane"
    end)
  end

  # --- scripted agent lines -----------------------------------------------------

  # A clean two-line session: init, then a successful result — the minimal
  # shape `AgentAdapter.ClaudeCode.Session` needs to report exactly one
  # `progress` event (from the `result` line's own summary) before exiting.
  defp claude_clean_exit_lines do
    [
      %{"type" => "system", "subtype" => "init", "session_id" => "thr_e2e"},
      %{"type" => "result", "is_error" => false, "result" => "implemented the approved slice"}
    ]
  end

  # The Codex equivalent: a started thread, then a completed turn — the
  # minimal shape `AgentAdapter.Codex.Session` needs to report exactly one
  # `progress` event ("Turn completed.") before exiting.
  defp codex_clean_exit_lines do
    [
      %{"type" => "thread.started", "thread_id" => "thr_e2e"},
      %{"type" => "turn.completed", "usage" => %{}}
    ]
  end

  # --- setup helpers -------------------------------------------------------------

  defp restore_env(key, {:ok, value}), do: Application.put_env(:sdd_orchestrator, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:sdd_orchestrator, key)

  defp drain_mix_shell do
    receive do
      {:mix_shell, _kind, _msg} -> drain_mix_shell()
    after
      0 -> :ok
    end
  end

  defp unique_tmp_dir(prefix) do
    dir = Path.join(System.tmp_dir!(), "sdd-e2e-#{prefix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp wait_until(fun, timeout \\ 5_000) do
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
        Process.sleep(10)
        do_wait_until(fun, deadline)
    end
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

  # Creates and proves a real local git fixture repository for this run's
  # own workspace, matching the pattern `CommandLifecycleTest.init_repository/4`
  # and `RequiredCheckRunnerTest.enqueue_start_with_real_repository/4` already
  # establish: seed it through the same `Workspace.prepare/1` primitive the
  # worker itself uses, so the working directory the "start" command later
  # names is exactly the one the real worker will resolve.
  defp init_repository(project, feature, run) do
    probe =
      DeliveryProtocolFixtures.manifest(%{
        "project_id" => project.id,
        "feature_id" => feature.id,
        "run_id" => run.id,
        "attempt_number" => 1,
        "required_checks" => @required_checks
      })

    {:ok, _workspace} = Workspace.prepare(probe)
    {:ok, directory} = Workspace.working_directory(probe)

    git!(directory, ["init", "--quiet"])
    git!(directory, ["commit", "--allow-empty", "--quiet", "--message", "base"])
    revision = git!(directory, ["rev-parse", "HEAD"])
    default_branch = git!(directory, ["symbolic-ref", "--short", "HEAD"])
    default_branch_sha_before = git!(directory, ["rev-parse", default_branch])

    {revision, directory, default_branch, default_branch_sha_before}
  end

  defp gateway_connection_pid(supervisor_pid) do
    supervisor_pid
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {GatewayConnection, pid, _type, _modules} when is_pid(pid) -> pid
      _other -> nil
    end)
  end

  defp stop_worker(pid) do
    if is_pid(pid) and Process.alive?(pid) do
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

  defp portable_identifier do
    salt = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    digest = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    "local-repo:v1:#{salt}:#{digest}"
  end
end
