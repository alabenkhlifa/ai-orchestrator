defmodule SddOrchestrator.Delivery.AgentAdapterTest do
  # The environment allowlist is proven against the operating system's real
  # environment, which no other test may be mutating at the same time.
  use ExUnit.Case, async: false

  alias SddOrchestrator.AgentAdapterDouble, as: Double
  alias SddOrchestrator.Delivery.AgentAdapter
  alias SddOrchestrator.Delivery.ExecutionManifest
  alias SddOrchestrator.Delivery.ProtocolCodec
  alias SddOrchestrator.Delivery.ProtocolLimits
  alias SddOrchestrator.Delivery.Worker.Workspace
  alias SddOrchestrator.DeliveryProtocolFixtures, as: Fixtures

  @command_id Fixtures.command_id()
  @worker_secret_name "SDD_AGENT_ADAPTER_TEST_SECRET"
  @worker_secret_value "s3cr3t-worker-value-never-for-the-agent"

  @projected_keys ~w(
    agent_ref approved_slice attempt_number continuation effective_revision_digest
    effective_revision_id feature_id manifest_digest project_id required_checks run_id
    starting_revision_digest starting_revision_id target_branch working_directory
  )

  setup do
    base = Path.join(System.tmp_dir!(), "sdd-agent-#{System.unique_integer([:positive])}")
    root = Path.join(base, "root")
    File.mkdir_p!(root)

    previous = Application.fetch_env(:sdd_orchestrator, :worker_workspace_root)
    Application.put_env(:sdd_orchestrator, :worker_workspace_root, root)
    System.put_env(@worker_secret_name, @worker_secret_value)

    restore = Double.install()

    on_exit(fn ->
      restore.()
      System.delete_env(@worker_secret_name)

      case previous do
        {:ok, value} -> Application.put_env(:sdd_orchestrator, :worker_workspace_root, value)
        :error -> Application.delete_env(:sdd_orchestrator, :worker_workspace_root)
      end

      File.rm_rf!(base)
    end)

    manifest = Fixtures.manifest()
    {:ok, _workspace} = Workspace.prepare(manifest)
    {:ok, directory} = Workspace.working_directory(manifest)

    %{base: base, manifest: manifest, directory: directory}
  end

  describe "configured adapter" do
    test "defaults to the unavailable stand-in when no agent is configured" do
      Application.delete_env(:sdd_orchestrator, :agent_adapter)

      assert AgentAdapter.adapter() == AgentAdapter.Unavailable
    end

    test "the unavailable stand-in refuses every question" do
      assert {:error, :agent_unavailable} = AgentAdapter.Unavailable.installed_version()
      assert {:error, :agent_unavailable} = AgentAdapter.Unavailable.start(%{})
      assert {:error, :agent_unavailable} = AgentAdapter.Unavailable.observe(%{})
    end

    test "uses the module the deployment configured" do
      assert AgentAdapter.adapter() == Double
    end

    test "an unconfigured deployment cannot launch anything", context do
      Application.delete_env(:sdd_orchestrator, :agent_adapter)

      assert {:error, :agent_unavailable} =
               AgentAdapter.launch(context.manifest, context.directory)
    end
  end

  describe "installed protocol version" do
    test "accepts a version this worker speaks" do
      assert {:ok, "1.4.0"} = AgentAdapter.version()

      Double.script(%{version: {:ok, "1"}})
      assert {:ok, "1"} = AgentAdapter.version()
    end

    test "refuses a major version this worker does not speak" do
      for reported <- ["0.9.1", "2.0.0", "11.0.0"] do
        Double.script(%{version: {:ok, reported}})

        assert {:error, :incompatible_agent_version} = AgentAdapter.version()
      end
    end

    test "refuses a version it cannot read" do
      for reported <- ["", "one", "1x.0", :v1] do
        Double.script(%{version: {:ok, reported}})

        assert {:error, :incompatible_agent_version} = AgentAdapter.version()
      end
    end

    test "reports an adapter that cannot answer as an unavailable agent" do
      Double.script(%{version: {:error, :enoent}})

      assert {:error, :agent_unavailable} = AgentAdapter.version()
    end

    test "is settled before anything is launched", context do
      Double.script(%{version: {:ok, "2.0.0"}})

      assert {:error, :incompatible_agent_version} =
               AgentAdapter.launch(context.manifest, context.directory)

      assert Double.requests() == []
    end
  end

  describe "agent input projection" do
    test "projects exactly the fields the approved work needs", context do
      %{manifest: manifest, directory: directory} = context

      assert {:ok, input} = AgentAdapter.project(manifest, directory)
      assert Enum.sort(Map.keys(input)) == @projected_keys

      assert input["project_id"] == manifest.project_id
      assert input["feature_id"] == manifest.feature_id
      assert input["run_id"] == manifest.run_id
      assert input["attempt_number"] == manifest.attempt_number
      assert input["approved_slice"] == manifest.approved_slice
      assert input["effective_revision_digest"] == manifest.effective_revision_digest
      assert input["manifest_digest"] == ExecutionManifest.digest(manifest)
      assert input["target_branch"] == manifest.target_branch
      assert input["required_checks"] == manifest.required_checks
      assert input["continuation"] == manifest.continuation
      assert input["working_directory"] == directory
    end

    test "carries the continuation reason that rebuilds a lost thread", context do
      resumed =
        Fixtures.manifest(%{
          "attempt_number" => 2,
          "continuation" => %{"reason" => "blocking_answer", "prior_attempt_number" => 1}
        })

      assert {:ok, input} = AgentAdapter.project(resumed, context.directory)

      assert input["continuation"] == %{
               "reason" => "blocking_answer",
               "prior_attempt_number" => 1
             }
    end

    test "carries no worker, control-plane, or repository credential", context do
      assert {:ok, input} = AgentAdapter.project(context.manifest, context.directory)

      refute Map.has_key?(input, "worker_ref")
      assert input["agent_ref"] == context.manifest.agent_ref

      for forbidden <- SddOrchestrator.Delivery.SecretBoundary.forbidden_keys() do
        refute Map.has_key?(input, forbidden)
      end
    end

    test "refuses a manifest carrying a secret-shaped reference", context do
      carrying = struct!(context.manifest, agent_ref: %{"api_key" => "ghp_notarealtoken"})

      assert {:error, :secret_field_rejected} =
               AgentAdapter.project(carrying, context.directory)
    end

    test "refuses a working directory that is not this run's", context do
      %{base: base, directory: directory, manifest: manifest} = context

      assert {:error, :workspace_escape} = AgentAdapter.project(manifest, base)
      assert {:error, :workspace_escape} = AgentAdapter.project(manifest, "/etc")
      assert {:error, :workspace_escape} = AgentAdapter.project(manifest, :not_a_path)

      assert {:error, :workspace_escape} =
               AgentAdapter.project(manifest, Path.join(directory, "nested"))
    end

    test "refuses a manifest whose identity was altered", context do
      tampered = struct!(context.manifest, run_id: "../escape")

      assert {:error, :workspace_escape} = AgentAdapter.project(tampered, context.directory)
    end

    test "refuses anything that is not a manifest", context do
      assert {:error, :invalid_agent_input} = AgentAdapter.project(%{}, context.directory)
      assert {:error, :invalid_agent_input} = AgentAdapter.project(nil, context.directory)
    end
  end

  describe "launch" do
    test "hands the agent the projection, the environment, and no thread", context do
      %{manifest: manifest, directory: directory} = context

      assert {:ok, launch} = AgentAdapter.launch(manifest, directory)
      assert {:ok, input} = AgentAdapter.project(manifest, directory)

      assert launch.agent_version == "1.4.0"
      assert launch.manifest == manifest
      assert launch.agent_input == input
      assert launch.thread_start == :new
      assert launch.thread_ref == Double.thread_ref()

      assert [request] = Double.requests()
      assert request.agent_input == input
      assert request.thread_ref == nil
      assert request.environment == AgentAdapter.environment()
    end

    test "launches only inside the proven working directory", context do
      assert {:error, :workspace_escape} = AgentAdapter.launch(context.manifest, context.base)
      assert Double.requests() == []
    end

    test "reports a refusing agent and an unavailable one distinctly", context do
      Double.script(%{start: :fail})

      assert {:error, :agent_launch_failed} =
               AgentAdapter.launch(context.manifest, context.directory)

      Double.script(%{start: :unavailable})

      assert {:error, :agent_unavailable} =
               AgentAdapter.launch(context.manifest, context.directory)
    end

    test "refuses a handle it cannot read", context do
      Double.script(%{start: :malformed_handle})

      assert {:error, :agent_launch_failed} =
               AgentAdapter.launch(context.manifest, context.directory)
    end

    test "refuses anything that is not a manifest", context do
      assert {:error, :invalid_agent_input} = AgentAdapter.launch(%{}, context.directory)
    end

    test "refuses a thread reference that is not one", context do
      assert {:error, :invalid_agent_input} =
               AgentAdapter.launch(context.manifest, context.directory, thread_ref: 17)
    end
  end

  describe "provider thread" do
    test "resumes the thread it was offered", context do
      assert {:ok, launch} =
               AgentAdapter.launch(context.manifest, context.directory, thread_ref: "thr_prior")

      assert launch.thread_start == :resumed
      assert launch.thread_ref == "thr_prior"
      assert [%{thread_ref: "thr_prior"}] = Double.requests()
    end

    test "starts a new thread when the provider will not resume", context do
      Double.script(%{start: :refuse_resume})

      assert {:ok, launch} =
               AgentAdapter.launch(context.manifest, context.directory, thread_ref: "thr_lost")

      assert launch.thread_start == :new
      assert launch.thread_ref == Double.thread_ref()

      assert [offered, rebuilt] = Double.requests()
      assert offered.thread_ref == "thr_lost"
      assert rebuilt.thread_ref == nil
      assert rebuilt.agent_input == offered.agent_input
    end

    test "rebuilds the new thread from the manifest and continuation reason", context do
      Double.script(%{start: :refuse_resume})

      retried =
        Fixtures.manifest(%{
          "attempt_number" => 3,
          "continuation" => %{"reason" => "manual_retry", "prior_attempt_number" => 2}
        })

      assert {:ok, launch} =
               AgentAdapter.launch(retried, context.directory, thread_ref: "thr_lost")

      assert launch.thread_start == :new
      assert [_offered, rebuilt] = Double.requests()
      assert rebuilt.agent_input["manifest_digest"] == ExecutionManifest.digest(retried)
      assert rebuilt.agent_input["continuation"]["reason"] == "manual_retry"
      assert rebuilt.agent_input["working_directory"] == context.directory
    end

    test "a lost thread never fails the attempt", context do
      for loss <- [:thread_expired, :thread_incompatible, :thread_not_found] do
        Double.install(%{start: :refuse_resume, thread_ref: "thr_#{loss}"})

        assert {:ok, launch} =
                 AgentAdapter.launch(context.manifest, context.directory, thread_ref: "thr_gone")

        assert launch.thread_start == :new
      end
    end

    test "refuses an agent claiming a resume nobody offered", context do
      Double.script(%{start: :claim_resume})

      assert {:error, :agent_launch_failed} =
               AgentAdapter.launch(context.manifest, context.directory)
    end
  end

  describe "environment allowlist" do
    test "carries values only for allowlisted names" do
      environment = Map.new(AgentAdapter.environment())

      carried =
        for {name, value} <- environment, not is_nil(value), name != "GIT_TERMINAL_PROMPT" do
          name
        end

      assert carried != []
      assert Enum.all?(carried, &(&1 in AgentAdapter.environment_allowlist()))
      assert environment["PATH"] == System.get_env("PATH")
    end

    test "clears every other variable the worker holds" do
      environment = Map.new(AgentAdapter.environment())

      assert Map.has_key?(environment, @worker_secret_name)
      assert environment[@worker_secret_name] == nil

      for {name, _value} <- System.get_env(),
          name not in AgentAdapter.environment_allowlist(),
          name != "GIT_TERMINAL_PROMPT" do
        assert environment[name] == nil
      end
    end

    test "forbids the agent from acquiring a credential by prompting" do
      assert Map.new(AgentAdapter.environment())["GIT_TERMINAL_PROMPT"] == "0"
    end

    test "no worker secret survives into anything the agent receives", context do
      assert {:ok, _launch} = AgentAdapter.launch(context.manifest, context.directory)
      assert [request] = Double.requests()

      refute Enum.any?(request.environment, fn {_name, value} ->
               value == @worker_secret_value
             end)

      refute inspect(request, limit: :infinity, printable_limit: :infinity) =~
               @worker_secret_value
    end
  end

  describe "event normalization" do
    setup context do
      Double.script(%{events: []})
      {:ok, launch} = AgentAdapter.launch(context.manifest, context.directory)

      %{launch: launch}
    end

    test "turns agent progress into an envelope the shared codec accepts", context do
      Double.script(%{events: [Double.progress_event()]})

      assert {:ok, observation} = observe(context.launch)
      assert [envelope] = observation.events
      assert :ok = ProtocolCodec.validate(envelope)

      assert envelope["type"] == "event"
      assert envelope["event_type"] == "progress"
      assert envelope["source"] == "agent"
      assert envelope["run_id"] == context.manifest.run_id
      assert envelope["attempt_number"] == context.manifest.attempt_number
      assert envelope["command_id"] == @command_id
      assert envelope["fence_token"] == 7
      assert envelope["sequence"] == 1
      assert envelope["occurred_at"] == Double.occurred_at()
      assert envelope["payload"] == Double.progress_event()["payload"]
      assert observation.terminal == nil
    end

    test "normalizes every event type an agent owns", context do
      types = AgentAdapter.agent_event_types()
      Double.script(%{events: Enum.map(types, &Double.progress_event(%{"type" => &1}))})

      assert {:ok, observation} = observe(context.launch)
      assert observation.dropped == []
      assert Enum.map(observation.events, & &1["event_type"]) == types
      assert Enum.all?(observation.events, &(ProtocolCodec.validate(&1) == :ok))
    end

    test "reports the terminal event that ended the stream", context do
      Double.script(%{
        events: [Double.progress_event(), Double.progress_event(%{"type" => "failed"})]
      })

      assert {:ok, observation} = observe(context.launch)
      assert observation.terminal == "failed"
      assert observation.last_sequence == 2
    end

    test "numbers the stream contiguously from the last sequence it was given", context do
      Double.script(%{events: List.duplicate(Double.progress_event(), 3)})

      assert {:ok, observation} = observe(context.launch, last_sequence: 4)
      assert Enum.map(observation.events, & &1["sequence"]) == [5, 6, 7]
      assert observation.last_sequence == 7
    end

    test "gives every event its own identity", context do
      Double.script(%{events: List.duplicate(Double.progress_event(), 2)})

      assert {:ok, observation} = observe(context.launch)
      assert [first, second] = Enum.map(observation.events, & &1["event_id"])
      refute first == second
    end

    test "drops an event type only the worker or the check runner may emit", context do
      Double.script(%{
        events: [
          Double.usurping_event("verification_completed"),
          Double.usurping_event("workspace_ready"),
          Double.usurping_event("canceled")
        ]
      })

      assert {:ok, observation} = observe(context.launch)
      assert observation.events == []

      assert observation.dropped == [
               {0, :unsupported_agent_event},
               {1, :unsupported_agent_event},
               {2, :unsupported_agent_event}
             ]
    end

    test "drops a malformed event without consuming a sequence", context do
      Double.script(%{
        events: [
          Double.progress_event(),
          Double.malformed_event(),
          "not an event at all",
          %{"type" => "progress"},
          Double.progress_event()
        ]
      })

      assert {:ok, observation} = observe(context.launch)
      assert Enum.map(observation.events, & &1["sequence"]) == [1, 2]

      assert observation.dropped == [
               {1, :unsupported_agent_event},
               {2, :invalid_agent_event},
               {3, :invalid_agent_event}
             ]
    end

    test "drops a secret-bearing event and forwards nothing raw", context do
      Double.script(%{events: [Double.secret_event(), Double.progress_event()]})

      assert {:ok, observation} = observe(context.launch)
      assert observation.dropped == [{0, :secret_field_rejected}]
      assert [envelope] = observation.events
      assert envelope["sequence"] == 1

      refute inspect(observation, limit: :infinity, printable_limit: :infinity) =~
               "ghp_thisisnotarealtokenatall"
    end

    test "drops an event the shared codec refuses", context do
      oversized = String.duplicate("x", ProtocolLimits.get(:max_payload_bytes) + 1)

      Double.script(%{
        events: [
          Double.untimed_event(),
          Double.progress_event(%{"payload" => %{"summary" => oversized}})
        ]
      })

      assert {:ok, observation} = observe(context.launch)
      assert observation.events == []
      assert observation.dropped == [{0, :invalid_timestamp}, {1, :payload_too_large}]
    end

    test "refuses an observation that is not bound to a command and fence", context do
      assert {:error, :invalid_agent_input} = AgentAdapter.observe(context.launch, [])

      assert {:error, :invalid_agent_input} =
               AgentAdapter.observe(context.launch, command_id: @command_id)

      assert {:error, :invalid_agent_input} =
               AgentAdapter.observe(context.launch, command_id: "not an id", fence_token: 7)

      assert {:error, :invalid_agent_input} =
               AgentAdapter.observe(context.launch, command_id: @command_id, fence_token: 0)

      assert {:error, :invalid_agent_input} =
               observe(context.launch, last_sequence: -1)
    end
  end

  describe "process failure" do
    setup context do
      {:ok, launch} = AgentAdapter.launch(context.manifest, context.directory)

      %{launch: launch}
    end

    test "an agent that exits is reported, not silently drained", context do
      Double.script(%{observe: :exit})

      assert {:error, :agent_exited} = observe(context.launch)
    end

    test "an agent that vanished is reported as unavailable", context do
      Double.script(%{observe: :unavailable})

      assert {:error, :agent_unavailable} = observe(context.launch)
    end
  end

  describe "agent double" do
    test "replays its scripted version, start outcome, and events", context do
      Double.script(%{version: {:ok, "1.9.3"}, events: [Double.progress_event()]})

      assert {:ok, "1.9.3"} = AgentAdapter.version()
      assert {:ok, launch} = AgentAdapter.launch(context.manifest, context.directory)
      assert {:ok, observation} = observe(launch)
      assert length(observation.events) == 1
    end

    test "records every start request in order", context do
      Double.script(%{start: :refuse_resume})

      assert {:ok, _launch} =
               AgentAdapter.launch(context.manifest, context.directory, thread_ref: "thr_one")

      assert {:ok, _launch} = AgentAdapter.launch(context.manifest, context.directory)

      assert Enum.map(Double.requests(), & &1.thread_ref) == ["thr_one", nil, nil]
    end

    test "launches no process and reaches no network", context do
      assert {:ok, launch} = AgentAdapter.launch(context.manifest, context.directory)

      assert is_reference(launch.handle.reference)
    end

    test "puts the previous configuration back when it is uninstalled", context do
      Application.put_env(:sdd_orchestrator, :agent_adapter, __MODULE__)
      restore = Double.install()

      assert AgentAdapter.adapter() == Double
      restore.()
      assert AgentAdapter.adapter() == __MODULE__

      Application.put_env(:sdd_orchestrator, :agent_adapter, Double)
      assert {:ok, _launch} = AgentAdapter.launch(context.manifest, context.directory)
    end
  end

  defp observe(launch, opts \\ []) do
    AgentAdapter.observe(
      launch,
      Keyword.merge([command_id: @command_id, fence_token: 7], opts)
    )
  end
end
