defmodule SddOrchestrator.Worker.RuntimeGovernanceEnvelopeSource do
  @moduledoc """
  Supplies the protocol envelope a durable command is delivered as, scoped to
  `SddOrchestrator.Worker.LocalWorkerRuntimeGovernanceEndToEndTest`.

  Mirrors `SddOrchestrator.Worker.EndToEndEnvelopeSource`'s own pattern
  (specs/33 Task 12) under its own name, so this file compiles and runs
  independently whether or not `end_to_end_test.exs` is compiled alongside it
  in the same `mix test` invocation.
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

defmodule SddOrchestrator.Worker.LocalWorkerRuntimeGovernanceEndToEndTest do
  @moduledoc """
  Task 7 proof (specs/34-local-worker-runtime-governance): one governed
  local-worker run, end to end, on a real local repository (AC-08).

  Composes exactly the same real machinery `specs/33-local-worker-run-execution`
  Task 12's own end-to-end proof (`SddOrchestrator.Worker.EndToEndTest`)
  established — real CLI pairing (`Mix.Tasks.Worker.Pair.run/1`), a real
  worker supervision tree (`Mix.Tasks.Worker.Start.start/1`), a real
  Bandit-backed gateway channel, a real local git fixture repository, and a
  scripted ("recorded") CLI agent double — but drives the run through the
  real `SddOrchestrator.Delivery.Start.start/4` action with one eligible
  personal AI connection bound to the same paired worker, instead of the
  hand-built fixtures `EndToEndTest` uses for its own (deliberately
  ungoverned) proof. That is what lets this scenario prove the governance
  layer composes with a real run rather than a fixture standing in for one.

  Only the `claude_code` agent is exercised here: `EndToEndTest` already
  proves both supported agents work unchanged at the transport/execution
  level, so this file's job is proving specs/34's governance layer composes
  with either, not re-proving agent-adapter behavior.

  Since `Start.start/4` builds its own `ExecutionManifest` internally (a
  private `manifest_for/4`), this scenario reconstructs an equivalent
  manifest from the run's and attempt's own persisted fields and the approved
  execution profile the rest of it comes from, and proves the reconstruction is
  exact by asserting its digest equals the one `Start.start/4` actually stored,
  before using it to build the worker command envelope.
  """

  use SddOrchestrator.DataCase, async: false

  import SddOrchestrator.AIRuntimeFixtures
  import SddOrchestrator.ProjectsFixtures

  alias Phoenix.PubSub
  alias SddOrchestrator.AIRuntime.AIRuntimeSession
  alias SddOrchestrator.ClaudeCodeCliFixture
  alias SddOrchestrator.Delivery.ArtifactStore
  alias SddOrchestrator.Delivery.CommandTransport.Channel, as: Transport
  alias SddOrchestrator.Delivery.ExecutionManifest

  alias SddOrchestrator.Delivery.{
    AgentRun,
    LocalWorkerRunGovernance,
    LocalWorkerRuntimeProjection,
    ProcessingDisclosure,
    Readiness,
    RunAttempt,
    Start,
    Suggestions
  }

  alias SddOrchestrator.Delivery.Worker.Branch
  alias SddOrchestrator.Delivery.Worker.Workspace
  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.DeliveryProtocolFixtures
  alias SddOrchestrator.Devices.{LocalWorker, Pairing}
  alias SddOrchestrator.ParticipationDeliveryDouble
  alias SddOrchestrator.Portability.HostedLocalRepositoryBinding
  alias SddOrchestrator.ReadinessGuidanceDouble
  alias SddOrchestrator.Repo
  alias SddOrchestrator.SpecificationFixtures
  alias SddOrchestrator.SpecificationStore
  alias SddOrchestrator.Worker.Configuration
  alias SddOrchestrator.Worker.GatewayConnection
  alias SddOrchestrator.Worker.RunState
  alias SddOrchestrator.Worker.RuntimeGovernanceEnvelopeSource, as: EnvelopeSource
  alias SddOrchestratorWeb.WorkerChannel

  # The one required check the approved profile carries. It is minimal, fast,
  # and deterministic for the same reason `EndToEndTest`'s own check is, and it
  # is spelled as a project command because a profile only accepts commands a
  # project actually runs. The fixture repository below carries the `Makefile`
  # that answers it.
  @check "make revision"
  @required_checks [%{"name" => @check, "command" => @check}]

  # A profile the assessment domain accepts, holding exactly that check.
  @profile_fields %{
    commands: [@check],
    required_checks: [@check],
    allowed_scope: ["lib"],
    gaps: [],
    conflicts: [],
    multi_root_blockers: []
  }

  # Matches `AIRuntimeFixtures`' own default catalog/quota `retrieved_at`, so
  # the pin this scenario drives through `Start.start/4` lands inside the
  # fixture catalog's freshness window instead of racing the real wall clock.
  @pin_time ~U[2026-08-03 12:00:00Z]

  setup do
    previous_root = Application.fetch_env(:sdd_orchestrator, :worker_workspace_root)
    previous_home = Application.fetch_env(:sdd_orchestrator, :worker_home)
    previous_adapter = Application.fetch_env(:sdd_orchestrator, :agent_adapter)
    previous_executable = Application.fetch_env(:sdd_orchestrator, :agent_executable)
    previous_shell = Mix.shell()
    previous_delivery = Application.get_env(:sdd_orchestrator, :participation_email_delivery)

    Mix.shell(Mix.Shell.Process)

    restore_readiness = ReadinessGuidanceDouble.install()

    Application.put_env(
      :sdd_orchestrator,
      :participation_email_delivery,
      ParticipationDeliveryDouble
    )

    ParticipationDeliveryDouble.succeed()

    on_exit(fn ->
      restore_env(:worker_workspace_root, previous_root)
      restore_env(:worker_home, previous_home)
      restore_env(:agent_adapter, previous_adapter)
      restore_env(:agent_executable, previous_executable)
      Mix.shell(previous_shell)
      restore_readiness.()

      if previous_delivery do
        Application.put_env(:sdd_orchestrator, :participation_email_delivery, previous_delivery)
      else
        Application.delete_env(:sdd_orchestrator, :participation_email_delivery)
      end
    end)

    on_exit(EnvelopeSource.install())

    bandit =
      start_supervised!(
        {Bandit, plug: SddOrchestratorWeb.Endpoint, scheme: :http, port: 0, startup_log: false}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    %{control_plane_address: "http://127.0.0.1:#{port}"}
  end

  describe "AC-08: one governed run end to end on a real local repository" do
    test "a governed run's session, live snapshot, and owner projection are real and correct",
         %{control_plane_address: base} do
      context = DeliveryFixtures.delivery_project_fixture()
      authority = context.workspace
      project = context.project
      owner = context.owner_actor
      owner_account = context.account

      # Every guided part is written, so readiness clears and this test reaches
      # the governed run it is about.
      feature =
        DeliveryFixtures.feature_fixture(project, owner_account, %{requirements: :filled})

      ready = prepare_ready_feature(authority, project, feature, owner)

      workspace_root = unique_tmp_dir("governance-workspace-root")
      home = unique_tmp_dir("governance-home")
      Application.put_env(:sdd_orchestrator, :worker_workspace_root, workspace_root)
      Application.put_env(:sdd_orchestrator, :worker_home, home)

      device_workspace = device_workspace_fixture()
      {:ok, %{code: code}} = Pairing.start_pairing(device_workspace.id)

      pair_argv = [
        "--code",
        code,
        "--control-plane",
        base,
        "--agent",
        "claude_code",
        "--agent-executable",
        ClaudeCodeCliFixture.streaming_script(claude_clean_exit_lines()),
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
      worker = Repo.get!(LocalWorker, config.worker_id)
      {:ok, worker} = Pairing.mark_seen(worker)

      # The direct binding insert `local_worker_run_governance_privacy_test.exs`
      # (Task 6) already established as the pattern for linking a project to a
      # paired worker without going through the separate
      # `HostedLocalRepositoryBindings.put_validated_binding/6` boundary
      # `specs/33`'s own end-to-end proof exercises — that boundary's own
      # authorization is already proven elsewhere and is not this task's
      # concern.
      %HostedLocalRepositoryBinding{}
      |> HostedLocalRepositoryBinding.changeset(%{
        project_id: project.id,
        worker_id: worker.id,
        last_validated_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.insert!()

      %{connection: connection} =
        runtime_session_context_fixture(%{account: owner_account, worker: worker})

      run_id = Ecto.UUID.generate()

      {revision, directory, _default_branch, _default_branch_sha_before} =
        init_repository(project, feature, run_id)

      # The run executes the contract the repository's owner approved, so the
      # profile in force is the one bound to the commit this fixture repository
      # actually has. Approval is append-only, so this later version wins over
      # the one the shared fixture seeded.
      profile =
        DeliveryFixtures.approve_profile!(owner_account.id, project,
          fields: @profile_fields,
          commit: revision,
          now: DateTime.add(DateTime.utc_now(), 3_600, :second)
        )

      assert {:ok, results} =
               Start.start(authority, owner, %{project: project, feature: ready},
                 run_id: run_id,
                 now: @pin_time
               )

      manifest = reconstruct_manifest(project, feature, run_id, profile, results)
      assert ExecutionManifest.digest(manifest) == results.attempt.manifest_digest

      envelope =
        DeliveryProtocolFixtures.command(%{
          "command_id" => results.command.id,
          "project_id" => project.id,
          "feature_id" => feature.id,
          "run_id" => run_id,
          "attempt_number" => 1,
          "fence_token" => 1,
          "expected_state_version" => results.command.expected_state_version,
          "manifest_digest" => results.attempt.manifest_digest,
          "payload" => %{"manifest" => ExecutionManifest.to_map(manifest)}
        })

      EnvelopeSource.script(results.command.id, envelope)

      :ok = PubSub.subscribe(SddOrchestrator.PubSub, WorkerChannel.topic(project.id))

      assert {:ok, supervisor_pid} = Mix.Tasks.Worker.Start.start(["--home", home])
      on_exit(fn -> stop_worker(supervisor_pid) end)

      wait_until(fn -> Transport.attached(project.id) != [] end)

      gateway_pid = gateway_connection_pid(supervisor_pid)
      assert is_pid(gateway_pid)

      socket = :sys.get_state(gateway_pid)
      gateway_token = socket.assigns.gateway_credential
      assert is_binary(gateway_token)

      assert Transport.deliver(results.command) == :ok

      assert_receive {:worker_event, %{"event_type" => "workspace_ready"} = ready_event}, 5_000
      assert ready_event["payload"]["branch"] == manifest.target_branch
      assert ready_event["payload"]["base_revision"] == revision

      assert_receive {:worker_heartbeat, %{"state" => "running"} = heartbeat_running}, 5_000

      assert_receive {:worker_event, %{"event_type" => "progress"} = progress_event}, 5_000

      assert_receive {:worker_event,
                      %{
                        "event_type" => "evidence",
                        "source" => "check",
                        "payload" =>
                          %{
                            "name" => @check,
                            "outcome" => "passed",
                            "exit_code" => 0
                          } = evidence_payload
                      } = evidence_event},
                     5_000

      assert {:ok, artifact} =
               ArtifactStore.fetch(authority, project.id, evidence_payload["artifact_ref"])

      assert String.trim(artifact.content) == revision

      assert_receive {:worker_event,
                      %{"event_type" => "verification_completed", "source" => "worker"} =
                        completion_event},
                     5_000

      assert completion_event["payload"]["commit_sha"] == revision

      assert_receive {:worker_heartbeat, %{"state" => "stopping"} = heartbeat_stopping}, 5_000

      wait_until(fn ->
        match?({:ok, %{current: %{lifecycle: "verification_completed"}}}, RunState.load(home))
      end)

      assert {:ok, true} = Branch.Repository.Git.branch_exists?(directory, manifest.target_branch)
      target_sha = git!(directory, ["rev-parse", manifest.target_branch])
      assert target_sha == revision

      assert {:ok, recorded} = SddOrchestrator.Delivery.CommandOutbox.fetch(results.command.id)

      # --- governance: the run this real scenario produced is really governed ---

      assert %LocalWorkerRunGovernance{} =
               governance = LocalWorkerRunGovernance.for_run(results.run.id)

      assert %AIRuntimeSession{} = session = Repo.get!(AIRuntimeSession, governance.session_id)
      assert session.connection_id == connection.id
      assert session.consumer_kind == "working_agent"
      assert session.consumer_ref == "local_worker_run:" <> results.run.id

      # --- live snapshot and combined projection, read from the real, now-
      # completed run and attempt rather than from a fixture standing in for
      # them ---

      final_run = Repo.get!(AgentRun, results.run.id)
      final_attempt = Repo.get_by!(RunAttempt, run_id: results.run.id, attempt_number: 1)

      assert {:ok, {:owner, projection}} =
               LocalWorkerRuntimeProjection.for_run(
                 final_run,
                 final_attempt,
                 project.id,
                 owner_account.id,
                 owner
               )

      assert projection.session_id == session.id
      assert projection.model == session.model
      assert projection.effort == session.reasoning_effort

      # `LocalWorkerRuntimeSnapshot.snapshot/2` reads `RunAttempt.state`
      # exactly as it stands, live: this is the run's real current attempt
      # state rather than a value this test invents, whatever it is.
      assert projection.snapshot.status == final_attempt.state
      assert projection.snapshot.status in RunAttempt.states()
      assert projection.snapshot.tokens == :unknown
      assert projection.snapshot.cost == :unknown

      assert is_integer(projection.snapshot.elapsed_seconds)
      assert projection.snapshot.elapsed_seconds >= 0

      # --- boundary: nothing this scenario wrote to the control plane, in
      # either specs/33's worker traffic or specs/34's own new governance
      # surfaces, carries a credential or an absolute filesystem path ---

      governance_payload = %{
        "run_id" => governance.run_id,
        "session_id" => governance.session_id,
        "consumer_ref" => session.consumer_ref,
        "connection_id" => session.connection_id,
        "model" => session.model,
        "effort" => session.reasoning_effort
      }

      refute_boundary_leaks(
        [
          ready_event,
          heartbeat_running,
          progress_event,
          evidence_event,
          completion_event,
          heartbeat_stopping,
          recorded.result,
          governance_payload
        ],
        [config.worker_credential, gateway_token, directory, workspace_root, home]
      )
    end
  end

  # --- setup helpers -------------------------------------------------------------

  defp prepare_ready_feature(authority, project, feature, owner) do
    ReadinessGuidanceDouble.script({:findings, []})

    {:ok, _current} =
      SpecificationStore.create(
        authority,
        project.id,
        SpecificationFixtures.specification_attrs(),
        actor_ref: "owner"
      )

    {:ok, _assessment} = Readiness.assess(authority, owner, %{project: project, feature: feature})

    {:ok, %{results: %{feature: ready}}} =
      Suggestions.promote(
        authority,
        owner,
        %{project: project, feature: feature},
        "ready:#{feature.id}"
      )

    {:ok, _confirmed} =
      ProcessingDisclosure.confirm(project.id, owner, ProcessingDisclosure.describe().digest)

    ready
  end

  # Rebuilds the exact manifest `Start.start/4`'s own private `manifest_for/4`
  # built internally, from the run's and attempt's own persisted fields and the
  # approved profile the rest of it comes from (`agent_ref`/`worker_ref` are
  # always `%{}` — `Start.start/4` never received opts for either, so
  # `manifest_for/4`'s own defaults apply). The digest equality asserted right
  # after calling this is what proves the reconstruction is exact rather than
  # merely plausible.
  defp reconstruct_manifest(project, feature, run_id, profile, results) do
    DeliveryProtocolFixtures.manifest(%{
      "project_id" => project.id,
      "feature_id" => feature.id,
      "run_id" => run_id,
      "attempt_number" => 1,
      "approved_slice" => results.run.approved_slice,
      "starting_revision_id" => results.run.starting_revision_id,
      "starting_revision_digest" => results.run.starting_revision_digest,
      "effective_revision_id" => results.attempt.effective_revision_id,
      "effective_revision_digest" => results.attempt.effective_revision_digest,
      "repository_base_revision" => profile.base_revision,
      "target_branch" => results.run.branch,
      "required_checks" => results.attempt.required_checks,
      "repository_root" => profile.root,
      "commands" => profile.commands,
      "allowed_scope" => profile.allowed_scope,
      "agent_ref" => %{},
      "worker_ref" => %{},
      "continuation" => %{"reason" => "initial", "prior_attempt_number" => nil}
    })
  end

  # --- boundary proof --------------------------------------------------------

  # Mirrors `SddOrchestrator.Worker.EndToEndTest`'s own `refute_boundary_leaks/2`:
  # one collected-and-scanned check over everything the scenario pushed to the
  # channel plus, here, the new governance row and pinned session summary,
  # rather than scattered ad hoc assertions.
  defp refute_boundary_leaks(collected, forbidden) do
    encoded = Jason.encode!(collected)

    Enum.each(forbidden, fn value ->
      refute String.contains?(encoded, value),
             "boundary leak: found #{inspect(value)} in worker traffic delivered to the control plane"
    end)
  end

  # --- scripted agent lines -----------------------------------------------------

  defp claude_clean_exit_lines do
    [
      %{"type" => "system", "subtype" => "init", "session_id" => "thr_governance_e2e"},
      %{"type" => "result", "is_error" => false, "result" => "implemented the approved slice"}
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

  # The required check has to be a command a project genuinely runs, so the
  # fixture repository carries the one the approved profile names. It prints
  # the commit the workspace is on, which is what the evidence artifact is then
  # checked against.
  #
  # The path is built from a directory this test created under the temporary
  # workspace root and carries nothing from a request. Documented false
  # positive.
  # sobelow_skip ["Traversal.FileModule"]
  defp write_revision_makefile(directory) do
    File.write!(
      Path.join(directory, "Makefile"),
      "revision:\n\t@git rev-parse HEAD\n"
    )
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

  # Mirrors `SddOrchestrator.Worker.EndToEndTest.init_repository/4`, taking a
  # caller-chosen `run_id` directly rather than an already-created `AgentRun`'s
  # id, since this scenario must seed the repository at the exact workspace
  # directory `Start.start/4` will bind to before it has created the run.
  defp init_repository(project, feature, run_id) do
    probe =
      DeliveryProtocolFixtures.manifest(%{
        "project_id" => project.id,
        "feature_id" => feature.id,
        "run_id" => run_id,
        "attempt_number" => 1,
        "required_checks" => @required_checks
      })

    {:ok, _workspace} = Workspace.prepare(probe)
    {:ok, directory} = Workspace.working_directory(probe)

    git!(directory, ["init", "--quiet"])
    write_revision_makefile(directory)
    git!(directory, ["add", "Makefile"])
    git!(directory, ["commit", "--quiet", "--message", "base"])
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
end
