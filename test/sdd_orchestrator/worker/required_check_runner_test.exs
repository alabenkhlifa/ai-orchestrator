defmodule SddOrchestrator.Worker.RequiredCheckRunnerEnvelopeSource do
  @moduledoc """
  Supplies the protocol envelope a durable command is delivered as, scoped to
  `SddOrchestrator.Worker.RequiredCheckRunnerTest`.

  Mirrors the pattern `SddOrchestrator.Worker.AgentEventDeliveryEnvelopeSource`
  and its siblings already establish, defined locally so this file's
  `mix test` invocation never depends on another test file being compiled
  alongside it.
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

defmodule SddOrchestrator.Worker.RequiredCheckRunnerTest do
  @moduledoc """
  Task 9 proof: run the attempt's required checks.

  Covers [AC-13] — once the agent's own observation loop reports a clean
  exit with no terminal event, `SddOrchestrator.Worker.RequiredCheckRunner`
  runs every check in the attempt's own manifest-bound contract for real, in
  the proven working directory, reports each one as its own `evidence`
  event, and emits the single trailing `verification_completed` event only
  when every one of them actually passed. A failing, timed-out, or unrunnable
  check still gets its own evidence event with a real outcome, and the batch
  ends `"failed"` rather than a completion.

  Runs over the real gateway (real `Bandit`, real
  `SddOrchestratorWeb.WorkerChannel`, real `CommandOutbox`/`Transport`, real
  `SddOrchestrator.Worker.GatewayConnection`) against a scripted `claude`
  stand-in (`SddOrchestrator.ClaudeCodeCliFixture`) and a real local git
  fixture repository, matching the pattern `AgentEventDeliveryTest` and
  `ExecutionPreparationTest` already establish. The agent's own script is
  deliberately minimal in every test here — what varies is each attempt's
  `required_checks` contract, not the agent's own output.

  That an agent's own claim of verification completion can never reach the
  channel at all is already proven at the adapter boundary in
  `Delivery.AgentAdapterTest` (the agent event vocabulary structurally
  excludes `"verification_completed"` — `AgentAdapter.normalize/2` has no
  mapping for it) and is not re-proven here.
  """

  use SddOrchestrator.DataCase, async: false

  import SddOrchestrator.AccountsFixtures
  import SddOrchestrator.ProjectsFixtures

  alias Phoenix.PubSub
  alias SddOrchestrator.Accounts.DeviceWorkspace
  alias SddOrchestrator.ClaudeCodeCliFixture, as: Fixture
  alias SddOrchestrator.Delivery.AgentAdapter
  alias SddOrchestrator.Delivery.CommandOutbox
  alias SddOrchestrator.Delivery.CommandTransport.Channel, as: Transport
  alias SddOrchestrator.Delivery.ExecutionManifest
  alias SddOrchestrator.Delivery.ProtocolCodec
  alias SddOrchestrator.Delivery.Worker.Workspace
  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.DeliveryProtocolFixtures
  alias SddOrchestrator.Devices.Pairing
  alias SddOrchestrator.Portability.HostedLocalRepositoryBindings
  alias SddOrchestrator.Projects.Project
  alias SddOrchestrator.Repo
  alias SddOrchestrator.Worker.Configuration
  alias SddOrchestrator.Worker.GatewayConnection
  alias SddOrchestrator.Worker.RequiredCheckRunnerEnvelopeSource, as: EnvelopeSource
  alias SddOrchestrator.Worker.RunState
  alias SddOrchestratorWeb.WorkerChannel

  # Fast enough to keep the suite quick, long enough that a slow CI tick
  # never races the assertions below.
  @observe_interval 30
  @digest_pattern ~r/\A[0-9a-f]{64}\z/

  setup do
    previous_root = Application.fetch_env(:sdd_orchestrator, :worker_workspace_root)
    previous_adapter = Application.fetch_env(:sdd_orchestrator, :agent_adapter)
    previous_executable = Application.fetch_env(:sdd_orchestrator, :agent_executable)

    root =
      Path.join(
        System.tmp_dir!(),
        "sdd-required-check-runner-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    Application.put_env(:sdd_orchestrator, :worker_workspace_root, root)
    Application.put_env(:sdd_orchestrator, :agent_adapter, AgentAdapter.ClaudeCode)

    on_exit(fn ->
      restore_env(:worker_workspace_root, previous_root)
      restore_env(:agent_adapter, previous_adapter)
      restore_env(:agent_executable, previous_executable)
      File.rm_rf!(root)
    end)

    on_exit(EnvelopeSource.install())

    bandit =
      start_supervised!(
        {Bandit, plug: SddOrchestratorWeb.Endpoint, scheme: :http, port: 0, startup_log: false}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    Application.put_env(
      :sdd_orchestrator,
      :agent_executable,
      Fixture.streaming_script(clean_exit_lines())
    )

    %{control_plane_address: "http://127.0.0.1:#{port}"}
  end

  describe "AC-13: each required check runs in the proven directory and reports its own evidence event" do
    test "a passing check and a failing check each produce their own outcome, and no completion is emitted",
         %{control_plane_address: base} do
      required_checks = [
        %{"name" => "repo_check", "command" => "test -d .git"},
        %{"name" => "boom", "command" => "exit 7"}
      ]

      %{envelope: envelope, home: home, pid: pid} =
        start_attempt(base, required_checks)

      on_exit(fn -> stop_gateway(pid) end)

      assert_receive {:worker_event, %{"event_type" => "workspace_ready"}}, 3_000
      assert_receive {:worker_event, %{"event_type" => "progress"}}, 3_000

      assert_receive {:worker_event,
                      %{
                        "event_type" => "evidence",
                        "source" => "check",
                        "payload" =>
                          %{
                            "kind" => "required_check",
                            "name" => "repo_check",
                            "outcome" => "passed",
                            "command" => "test -d .git",
                            "exit_code" => 0
                          } = passed_payload
                      }},
                     3_000

      assert Regex.match?(@digest_pattern, passed_payload["digest"])
      assert passed_payload["redacted"] == false

      assert_receive {:worker_event,
                      %{
                        "event_type" => "evidence",
                        "source" => "check",
                        "payload" => %{
                          "name" => "boom",
                          "outcome" => "failed",
                          "command" => "exit 7",
                          "exit_code" => 7
                        }
                      }},
                     3_000

      refute_receive {:worker_event, %{"event_type" => "verification_completed"}}, 500

      wait_until(fn ->
        match?({:ok, %{current: %{lifecycle: "failed"}}}, RunState.load(home))
      end)

      {:ok, manifest} = ProtocolCodec.manifest(envelope)
      {:ok, workspace} = Workspace.prepare(manifest)
      refute File.exists?(Path.join(workspace, "run.lock"))
    end

    test "an unrunnable check is reported with its own real outcome instead of crashing the worker",
         %{control_plane_address: base} do
      required_checks = [
        %{"name" => "missing", "command" => "definitely-not-a-real-command-xyz123"}
      ]

      %{home: home, pid: pid} =
        start_attempt(base, required_checks)

      on_exit(fn -> stop_gateway(pid) end)

      assert_receive {:worker_event, %{"event_type" => "workspace_ready"}}, 3_000
      assert_receive {:worker_event, %{"event_type" => "progress"}}, 3_000

      assert_receive {:worker_event,
                      %{
                        "event_type" => "evidence",
                        "payload" => %{"name" => "missing", "outcome" => "failed"} = payload
                      }},
                     3_000

      # `sh -c` itself absorbs "command not found" into a normal, non-raising
      # exit status (POSIX shells report 127) rather than the worker ever
      # needing to rescue an exception for this case.
      assert payload["exit_code"] == 127

      refute_receive {:worker_event, %{"event_type" => "verification_completed"}}, 500

      wait_until(fn ->
        match?({:ok, %{current: %{lifecycle: "failed"}}}, RunState.load(home))
      end)
    end

    test "a check that exceeds its timeout is reported failed with no real exit status",
         %{control_plane_address: base} do
      required_checks = [%{"name" => "slow", "command" => "sleep 5"}]
      timeout_ms = 50

      %{home: home, pid: pid} =
        start_attempt(base, required_checks, check_timeout_ms: timeout_ms)

      on_exit(fn -> stop_gateway(pid) end)

      assert_receive {:worker_event, %{"event_type" => "workspace_ready"}}, 3_000
      assert_receive {:worker_event, %{"event_type" => "progress"}}, 3_000

      assert_receive {:worker_event,
                      %{
                        "event_type" => "evidence",
                        "payload" => %{
                          "name" => "slow",
                          "outcome" => "failed",
                          "exit_code" => -1,
                          "duration_ms" => ^timeout_ms
                        }
                      }},
                     3_000

      refute_receive {:worker_event, %{"event_type" => "verification_completed"}}, 500

      wait_until(fn ->
        match?({:ok, %{current: %{lifecycle: "failed"}}}, RunState.load(home))
      end)
    end
  end

  describe "AC-13: verification completes only when every required check actually passed" do
    test "each check reports its own passing evidence, then one verification_completed event carries the real identity, and the lock releases",
         %{control_plane_address: base} do
      required_checks = [
        %{"name" => "a", "command" => "true"},
        %{"name" => "b", "command" => "true"}
      ]

      %{envelope: envelope, home: home, pid: pid} =
        start_attempt(base, required_checks)

      on_exit(fn -> stop_gateway(pid) end)

      assert_receive {:worker_event, %{"event_type" => "workspace_ready"}}, 3_000
      assert_receive {:worker_event, %{"event_type" => "progress"}}, 3_000

      assert_receive {:worker_event,
                      %{
                        "event_type" => "evidence",
                        "payload" => %{"name" => "a", "outcome" => "passed"}
                      } = first_evidence},
                     3_000

      assert_receive {:worker_event,
                      %{
                        "event_type" => "evidence",
                        "payload" => %{"name" => "b", "outcome" => "passed"}
                      } = second_evidence},
                     3_000

      assert_receive {:worker_event,
                      %{
                        "event_type" => "verification_completed",
                        "source" => "worker"
                      } = completion},
                     3_000

      sequences = [
        first_evidence["sequence"],
        second_evidence["sequence"],
        completion["sequence"]
      ]

      assert sequences == Enum.sort(sequences)
      assert length(Enum.uniq(sequences)) == 3

      {:ok, manifest} = ProtocolCodec.manifest(envelope)
      assert completion["payload"]["branch"] == manifest.target_branch
      assert completion["payload"]["revision_id"] == manifest.effective_revision_id
      assert is_binary(completion["payload"]["commit_sha"])

      wait_until(fn ->
        match?({:ok, %{current: %{lifecycle: "verification_completed"}}}, RunState.load(home))
      end)

      {:ok, workspace} = Workspace.prepare(manifest)
      refute File.exists?(Path.join(workspace, "run.lock"))
    end
  end

  # --- setup helpers -----------------------------------------------------

  defp clean_exit_lines do
    [
      %{"type" => "system", "subtype" => "init", "session_id" => "thr_checks"},
      %{"type" => "result", "is_error" => false, "result" => "implemented it"}
    ]
  end

  # Builds a real run/attempt/manifest/command bound to a real local git
  # fixture repository, delivers it over a freshly started real
  # `GatewayConnection`, and subscribes the calling test process to the
  # project's PubSub topic before returning — so every test body only needs
  # to `assert_receive` from here on. Returns the started connection's `pid`
  # so the caller can `stop_gateway/1` it on exit.
  defp start_attempt(base, required_checks, opts \\ []) do
    %{project: project, feature: feature, run: run, credential: credential, worker: worker} =
      paired_and_bound_project()

    {command, envelope, attempt} =
      enqueue_start_with_real_repository(project, feature, run, required_checks)

    EnvelopeSource.script(command.id, envelope)

    :ok = PubSub.subscribe(SddOrchestrator.PubSub, WorkerChannel.topic(project.id))

    home = tmp_home()
    config = build_config(base, credential, project.id, worker.id)

    start_opts =
      [home: home, observe_interval: @observe_interval] ++
        case Keyword.fetch(opts, :check_timeout_ms) do
          {:ok, value} -> [check_timeout_ms: value]
          :error -> []
        end

    {:ok, pid} = GatewayConnection.start_link(config, start_opts)

    wait_until(fn -> Transport.attached(project.id) != [] end)
    assert Transport.deliver(command) == :ok

    %{
      project: project,
      envelope: envelope,
      command: command,
      attempt: attempt,
      home: home,
      pid: pid
    }
  end

  # --- helpers -------------------------------------------------------------

  defp restore_env(key, {:ok, value}), do: Application.put_env(:sdd_orchestrator, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:sdd_orchestrator, key)

  defp tmp_home do
    dir =
      Path.join(
        System.tmp_dir!(),
        "worker-required-check-runner-test-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp build_config(control_plane_address, worker_credential, project_id, worker_id) do
    %Configuration{
      control_plane_address: control_plane_address,
      device_workspace_id: Ecto.UUID.generate(),
      worker_credential: worker_credential,
      agent_adapter: "claude_code",
      agent_executable: "/usr/local/bin/claude",
      workspace_root: System.tmp_dir!(),
      project_id: project_id,
      worker_id: worker_id
    }
  end

  defp stop_gateway(pid) do
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

  defp enqueue_start_with_real_repository(project, feature, run, required_checks) do
    attempt_number = 1
    fence_token = 1

    probe =
      DeliveryProtocolFixtures.manifest(%{
        "project_id" => project.id,
        "feature_id" => feature.id,
        "run_id" => run.id,
        "attempt_number" => attempt_number,
        "required_checks" => required_checks
      })

    {:ok, _workspace} = Workspace.prepare(probe)
    {:ok, directory} = Workspace.working_directory(probe)

    git!(directory, ["init", "--quiet"])
    git!(directory, ["commit", "--allow-empty", "--quiet", "--message", "base"])
    revision = git!(directory, ["rev-parse", "HEAD"])

    continuation = %{"reason" => "initial", "prior_attempt_number" => nil}

    manifest =
      DeliveryProtocolFixtures.manifest(%{
        "project_id" => project.id,
        "feature_id" => feature.id,
        "run_id" => run.id,
        "attempt_number" => attempt_number,
        "repository_base_revision" => revision,
        "continuation" => continuation,
        "required_checks" => required_checks
      })

    digest = ExecutionManifest.digest(manifest)

    attempt =
      DeliveryFixtures.attempt_fixture(run, %{
        attempt_number: attempt_number,
        fence_token: fence_token,
        manifest_digest: digest,
        continuation_reason: continuation["reason"]
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
        "attempt_number" => attempt_number,
        "fence_token" => fence_token,
        "expected_state_version" => command.expected_state_version,
        "manifest_digest" => digest,
        "payload" => %{"manifest" => ExecutionManifest.to_map(manifest)}
      })

    {command, envelope, attempt}
  end

  defp paired_and_bound_project do
    account = account_fixture()
    personal_workspace = workspace_fixture(account)
    device_workspace = %DeviceWorkspace{id: Ecto.UUID.generate()}
    project = local_project_fixture(personal_workspace, portable_identifier())
    feature = DeliveryFixtures.feature_fixture(project, account)
    run = DeliveryFixtures.run_fixture(project, feature)

    {worker, credential} = available_worker_fixture(device_workspace)

    {:ok, %{binding: _binding}} =
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
      device_workspace: device_workspace
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
        os_major: "15",
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
