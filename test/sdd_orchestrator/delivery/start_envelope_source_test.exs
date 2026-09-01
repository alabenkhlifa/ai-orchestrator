defmodule SddOrchestrator.Delivery.CommandTransport.StartEnvelopeSourceTest do
  @moduledoc """
  Task 12 proof: a press in the real product reaches the worker.

  Everything under test starts from one genuine `Start.start/4`, so the
  command, the run, the attempt, and the approved profile are the records the
  product actually wrote rather than a hand-built map. What is proved is the
  last hop the earlier tasks left open: the stored command becomes an envelope
  the shared codec accepts, the configuration development and production run
  carries it to a worker joined on the project topic, a command that cannot be
  turned into an envelope stays queued instead of being lost or failed, and
  neither configuration key is answered by a module from the test suite.
  """
  use SddOrchestrator.DataCase, async: false

  import Phoenix.ChannelTest, except: [join: 2, join: 3, join: 4]

  alias SddOrchestrator.Delivery.CommandOutbox
  alias SddOrchestrator.Delivery.CommandTransport
  alias SddOrchestrator.Delivery.CommandTransport.StartEnvelopeSource
  alias SddOrchestrator.Delivery.DeliveryStore
  alias SddOrchestrator.Delivery.Dispatcher
  alias SddOrchestrator.Delivery.ExecutionManifest
  alias SddOrchestrator.Delivery.ProcessingDisclosure
  alias SddOrchestrator.Delivery.ProtocolCodec
  alias SddOrchestrator.Delivery.Readiness
  alias SddOrchestrator.Delivery.RunCommand
  alias SddOrchestrator.Delivery.Start
  alias SddOrchestrator.Delivery.Suggestions
  alias SddOrchestrator.Delivery.WorkerProtocol
  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.ParticipationDeliveryDouble
  alias SddOrchestrator.ReadinessGuidanceDouble
  alias SddOrchestrator.Repo
  alias SddOrchestrator.WorkerDouble

  @boundary [
    execution_location: "this computer",
    agent_provider: "configured-agent",
    model_provider: "configured-model",
    transfers: []
  ]

  setup do
    on_exit(ReadinessGuidanceDouble.install())

    for {key, value} <- [
          participation_email_delivery: ParticipationDeliveryDouble,
          processing_boundary: @boundary
        ] do
      previous = Application.get_env(:sdd_orchestrator, key)
      Application.put_env(:sdd_orchestrator, key, value)
      on_exit(fn -> restore(key, previous) end)
    end

    ParticipationDeliveryDouble.succeed()

    context = DeliveryFixtures.delivery_project_fixture()

    feature =
      DeliveryFixtures.feature_fixture(context.project, context.account, %{
        requirements: :filled
      })

    started = start_run(context, feature)

    %{
      authority: context.workspace,
      project: context.project,
      owner: context.owner_actor,
      run: started.run,
      attempt: started.attempt,
      command: recorded(started.command)
    }
  end

  describe "the envelope a stored start command becomes" do
    test "the shared codec accepts it and it carries the run's own manifest", %{
      command: command,
      run: run,
      attempt: attempt
    } do
      assert {:ok, envelope} = StartEnvelopeSource.envelope(command)

      assert ProtocolCodec.validate(envelope) == :ok
      assert {:ok, _encoded} = ProtocolCodec.encode(envelope)

      assert envelope["type"] == "command"
      assert envelope["protocol_version"] == WorkerProtocol.version()
      assert envelope["command_id"] == command.id
      assert envelope["project_id"] == command.project_id
      assert envelope["run_id"] == run.id
      assert envelope["feature_id"] == run.feature_id
      assert envelope["operation"] == "start"
      assert envelope["expected_state_version"] == command.expected_state_version
      assert envelope["attempt_number"] == attempt.attempt_number
      assert envelope["fence_token"] == attempt.fence_token

      assert {:ok, manifest} = ProtocolCodec.manifest(envelope)
      assert ExecutionManifest.digest(manifest) == command.manifest_digest
      assert manifest.target_branch == run.branch
      assert manifest.approved_slice == run.approved_slice
      assert manifest.repository_base_revision == DeliveryFixtures.base_revision()
    end

    test "a command whose instruction it cannot rebuild is refused", %{
      command: %RunCommand{} = command
    } do
      assert StartEnvelopeSource.envelope(%RunCommand{command | operation: "cancel"}) ==
               {:error, :unsupported_operation}

      assert StartEnvelopeSource.envelope(%RunCommand{command | operation: "retry"}) ==
               {:error, :unsupported_operation}
    end

    test "a command naming no readable project is refused", %{
      command: %RunCommand{} = command
    } do
      assert StartEnvelopeSource.envelope(%RunCommand{command | project_id: "not a project"}) ==
               {:error, :authority_unavailable}

      assert StartEnvelopeSource.envelope(%RunCommand{command | project_id: Ecto.UUID.generate()}) ==
               {:error, :authority_unavailable}
    end
  end

  describe "delivery through the configured transport" do
    test "a worker joined on the project topic receives the started run's command", %{
      project: project,
      command: command
    } do
      install_configured_transport(:dev)
      {:ok, _reply, _channel} = WorkerDouble.attach(project.id)

      assert %{delivered: 1} = Dispatcher.dispatch_now(owner: "test-dispatcher")

      assert_push "command", pushed
      assert pushed["command_id"] == command.id
      assert pushed["manifest_digest"] == command.manifest_digest
      assert ProtocolCodec.validate(pushed) == :ok

      delivered = Repo.get!(RunCommand, command.id)
      assert delivered.state == "delivered"
      assert delivered.delivery_count == 1
    end

    test "no attached worker leaves the command queued", %{command: command} do
      install_configured_transport(:dev)

      assert CommandTransport.deliver(command) == {:error, :no_worker}
      assert Repo.get!(RunCommand, command.id).state == "pending"
    end
  end

  describe "a command whose envelope cannot be built" do
    test "stays queued rather than delivered or failed", %{
      authority: authority,
      project: project,
      attempt: attempt,
      command: command
    } do
      # The attempt this command was enqueued for is superseded before the
      # dispatcher reaches it, so there is nothing left to build the run's
      # instruction from and delivering it would run against another attempt.
      {:ok, _superseded} =
        DeliveryStore.commit(authority, project.id, [
          {:attempt, {:transition_attempt, attempt, "superseded"}}
        ])

      install_configured_transport(:dev)
      {:ok, _reply, _channel} = WorkerDouble.attach(project.id)

      assert {:error, :attempt_unavailable} = StartEnvelopeSource.envelope(command)
      assert %{delivered: 0} = Dispatcher.dispatch_now(owner: "test-dispatcher")
      refute_push "command", %{}

      queued = Repo.get!(RunCommand, command.id)
      assert queued.state == "claimed"
      assert queued.delivery_count == 0
      assert queued.delivered_at == nil
      assert queued.failure_code == nil

      # And it is still work the queue will hand out again once the claim it is
      # holding expires.
      later = DateTime.add(DateTime.utc_now(), 120, :second)
      assert CommandOutbox.release_expired(now: later) == 1
      assert CommandOutbox.pending_count(now: later) == 1
    end
  end

  describe "the configuration development and production run" do
    test "both keys name a product module, never one from the test suite" do
      for {path, env} <- [{"config/dev.exs", :dev}, {"config/prod.exs", :prod}] do
        configuration = read_configuration(path, env)

        assert configuration[:command_transport] ==
                 SddOrchestrator.Delivery.CommandTransport.Channel

        assert configuration[:command_envelope_source] == StartEnvelopeSource

        for key <- [:command_transport, :command_envelope_source] do
          source = to_string(configuration[key].module_info(:compile)[:source])

          assert String.starts_with?(source, Path.join(File.cwd!(), "lib/"))
          refute String.starts_with?(source, Path.join(File.cwd!(), "test/"))
        end
      end
    end
  end

  # Installs the transport and envelope source one environment's own
  # configuration file supplies, so what is exercised here is the wiring a
  # server actually boots with rather than a pair chosen by this test.
  defp install_configured_transport(env) do
    configuration = read_configuration("config/#{env}.exs", env)

    for key <- [:command_transport, :command_envelope_source] do
      previous = Application.get_env(:sdd_orchestrator, key)
      Application.put_env(:sdd_orchestrator, key, configuration[key])
      on_exit(fn -> restore(key, previous) end)
    end
  end

  # Reading `config/dev.exs` runs its own `.env` loader, which sets operating
  # system variables in this VM. Anything it introduced is removed again so no
  # later test reads a value this one brought in.
  defp read_configuration(path, env) do
    before = System.get_env()
    on_exit(fn -> discard_added_env(before) end)

    path
    |> Path.expand(File.cwd!())
    |> Config.Reader.read!(env: env)
    |> Keyword.fetch!(:sdd_orchestrator)
  end

  defp discard_added_env(before) do
    System.get_env()
    |> Map.drop(Map.keys(before))
    |> Enum.each(fn {key, _value} -> System.delete_env(key) end)
  end

  defp restore(key, nil), do: Application.delete_env(:sdd_orchestrator, key)
  defp restore(key, previous), do: Application.put_env(:sdd_orchestrator, key, previous)

  # One real press: the feature is checked, promoted, its boundary confirmed,
  # and development started through the same calls the feature page makes.
  defp start_run(context, feature) do
    ReadinessGuidanceDouble.script({:findings, []})

    {:ok, _assessment} =
      Readiness.assess(context.workspace, context.owner_actor, %{
        project: context.project,
        feature: feature
      })

    {:ok, %{results: %{feature: ready}}} =
      Suggestions.promote(
        context.workspace,
        context.owner_actor,
        %{project: context.project, feature: feature},
        "ready:#{feature.id}"
      )

    {:ok, _confirmed} =
      ProcessingDisclosure.confirm(
        context.project.id,
        context.owner_actor,
        ProcessingDisclosure.describe().digest
      )

    {:ok, results} =
      Start.start(context.workspace, context.owner_actor, %{
        project: context.project,
        feature: ready
      })

    results
  end

  defp recorded(command) do
    {:ok, stored} = CommandOutbox.fetch(command.id)

    stored
  end
end
