defmodule SddOrchestrator.Privacy.DeliveryRoutingBoundaryEnvelopeSource do
  @moduledoc """
  Supplies the protocol envelope a durable command is delivered as, for this
  task's own worker-command routing proof.

  A private copy of the same seam `SddOrchestratorWeb.WorkerChannelEnvelopeSource`
  (Task 19) already exercises, kept local to this file: `test/support/` files
  are shared across every test file that compiles them, but a module defined
  inside another test file is not, so this task cannot reuse that one without
  editing it — which is out of this task's ownership.
  """
  @behaviour SddOrchestrator.Delivery.CommandTransport.EnvelopeSource

  @key {__MODULE__, :envelopes}

  @doc "Installs this source for one test and returns its restore function."
  def install do
    original = Application.get_env(:sdd_orchestrator, :command_envelope_source)
    Application.put_env(:sdd_orchestrator, :command_envelope_source, __MODULE__)
    Process.put(@key, %{})

    fn -> Application.put_env(:sdd_orchestrator, :command_envelope_source, original) end
  end

  @doc "Scripts the envelope one command is delivered as."
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

defmodule SddOrchestrator.Privacy.DeliveryRoutingBoundaryTest do
  @moduledoc """
  Task 5 proof for specs/18 (AC-06): browser, worker, model, preview, hosted,
  and device runtime paths carry no forbidden analytics, credential,
  participant email, provider reuse, or durable hosted device-project copy.

  This is deliberately not a fifth detector. Credential and email absence is
  proved by scanning real, representative crossed traffic with
  `SddOrchestrator.Privacy.DeliveryContentBoundary` (Task 3); provider-purpose
  boundaries are proved with `SddOrchestrator.Privacy.DeliveryDataUsePolicy`
  (Task 4). What this task adds is driving genuine Slice 07 call sites — the
  worker channel, the configured agent and preview adapters, the dual-authority
  delivery store, and the guided-delivery LiveView routes under the router's
  real Content-Security-Policy — and inspecting what those real paths actually
  carried, rather than re-testing the classification or the policy in the
  abstract.

  "Browser-network capture" here is the same-origin, per-request-nonce
  Content-Security-Policy the `:browser` pipeline already applies to every
  route (`SddOrchestratorWeb.Router.put_content_security_policy/2`): a
  `connect-src 'self'` CSP is what makes an analytics or tracking beacon from
  the page provably impossible without a live browser, because the browser
  itself refuses any such connection before it leaves the page. This suite
  proves that contract holds on the guided-delivery screens specifically
  (`content_security_policy_test.exs` only proves it for the home page and the
  passwordless pages).

  Nothing here runs a live provider, a real browser, or the Playwright browser
  matrix (a slice-verification-gate concern) — every provider-facing call is
  driven against `SddOrchestrator.AgentAdapterDouble` or
  `SddOrchestrator.PreviewAdapterDouble`, and every worker-facing call is
  driven against `SddOrchestrator.WorkerDouble`.
  """
  use SddOrchestratorWeb.ConnCase, async: false

  import Phoenix.ChannelTest, except: [join: 2, join: 3, join: 4]

  alias Phoenix.PubSub

  alias SddOrchestrator.Accounts.DeviceWorkspace
  alias SddOrchestrator.AgentAdapterDouble

  alias SddOrchestrator.Delivery.{
    ActivityEntry,
    AgentAdapter,
    AgentRun,
    CommandOutbox,
    DeliveryStore,
    ExecutionManifest,
    Previews,
    RunAttempt,
    RunCommand
  }

  alias SddOrchestrator.Delivery.CommandTransport.Channel, as: Transport
  alias SddOrchestrator.Delivery.Worker.Workspace
  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.DeliveryProtocolFixtures
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.DeviceStore.Local
  alias SddOrchestrator.ParticipationDeliveryDouble
  alias SddOrchestrator.PreviewAdapterDouble
  alias SddOrchestrator.Privacy.DeliveryContentBoundary, as: ContentBoundary
  alias SddOrchestrator.Privacy.DeliveryDataUsePolicy, as: Policy
  alias SddOrchestrator.Privacy.DeliveryRoutingBoundaryEnvelopeSource, as: EnvelopeSource
  alias SddOrchestrator.Repo
  alias SddOrchestrator.WorkerDouble
  alias SddOrchestratorWeb.WorkerChannel

  # The exact projected agent-input field set `AgentAdapterTest` (Task-owned,
  # approved Slice 07 test) already pins for `AgentAdapter.project/2`. Reusing
  # it here — rather than inventing a second copy of "what an agent may see" —
  # is what makes "only the approved opaque per-run identifiers crossed" a
  # comparison against the product's own documented contract.
  @agent_projected_keys ~w(
    agent_ref approved_slice attempt_number continuation effective_revision_digest
    effective_revision_id feature_id manifest_digest project_id required_checks run_id
    starting_revision_digest starting_revision_id target_branch working_directory
  )

  # The exact `PreviewAdapter.request/0` field set (`preview_adapter.ex`'s own
  # `@type request`), plus the `credential_ref` `PreviewAdapter.request/2`
  # always adds from configuration before the adapter is called.
  @preview_request_keys ~w(
    attempt_id branch commit_sha credential_ref feature_id path project_id
    provider request_key run_id
  )a

  # A closed, named vocabulary for "this request configures training or
  # secondary-use consent" — grepping the entire `lib/sdd_orchestrator/delivery/`
  # tree found none of this vocabulary anywhere in the product's source, so its
  # absence from real recorded provider requests is the structural proof this
  # task owns (see the moduledoc). This is not a general secret/email
  # detector — those stay owned by `DeliveryContentBoundary` (Task 3).
  @training_use_keys ~w(
    training_consent training_use training_opt_in model_training_opt_in
    data_retention_opt_in retention_opt_in consent consent_to_training
    share_for_training improve_model opt_in
  )

  describe "guided-delivery browser routes carry the strict same-origin CSP" do
    setup do
      previous = Application.get_env(:sdd_orchestrator, :participation_email_delivery)

      Application.put_env(
        :sdd_orchestrator,
        :participation_email_delivery,
        ParticipationDeliveryDouble
      )

      ParticipationDeliveryDouble.succeed()

      on_exit(fn ->
        if previous do
          Application.put_env(:sdd_orchestrator, :participation_email_delivery, previous)
        else
          Application.delete_env(:sdd_orchestrator, :participation_email_delivery)
        end
      end)

      %{project: project, account: account} = DeliveryFixtures.delivery_project_fixture()
      feature = DeliveryFixtures.feature_fixture(project, account)

      %{project: project, feature: feature, account: account}
    end

    test "the feature board carries the same-origin, no-analytics CSP [AC-06]", %{
      conn: conn,
      project: project,
      account: account
    } do
      response = conn |> log_in_account(account) |> get(~p"/projects/#{project.id}/features")

      assert html_response(response, 200)
      assert_same_origin_csp(response)
    end

    test "the feature detail screen carries the same-origin, no-analytics CSP [AC-06]", %{
      conn: conn,
      project: project,
      feature: feature,
      account: account
    } do
      response =
        conn
        |> log_in_account(account)
        |> get(~p"/projects/#{project.id}/features/#{feature.id}")

      assert html_response(response, 200)
      assert_same_origin_csp(response)
    end
  end

  describe "worker command, event, and heartbeat routing" do
    setup do
      on_exit(EnvelopeSource.install())

      context = DeliveryFixtures.delivery_project_fixture()
      feature = DeliveryFixtures.feature_fixture(context.project, context.account)
      run = DeliveryFixtures.run_fixture(context.project, feature)

      %{project: context.project, feature: feature, run: run}
    end

    test "a dispatched start command carries no credential, email, or field beyond the closed protocol vocabulary [AC-06]",
         %{project: project, feature: feature, run: run} do
      {command, envelope} = enqueue_start(project, feature, run)
      EnvelopeSource.script(command.id, envelope)
      {:ok, _reply, _channel} = WorkerDouble.attach(project.id)

      assert Transport.deliver(command) == :ok
      assert_push "command", ^envelope

      assert ContentBoundary.scan_structure(envelope, "worker_command") == :ok
      refute_training_use_keys(envelope, "worker_command")

      # Only the closed worker-protocol field set crossed — no extra, stable,
      # or device-shaped identifier rode along with it.
      assert Enum.sort(Map.keys(envelope)) ==
               Enum.sort(Map.keys(DeliveryProtocolFixtures.command()))
    end

    test "an emitted worker event carries no credential, email, or field beyond the closed protocol vocabulary [AC-06]",
         %{project: project, feature: feature, run: run} do
      {command, _envelope} = enqueue_start(project, feature, run)
      PubSub.subscribe(SddOrchestrator.PubSub, WorkerChannel.topic(project.id))
      {:ok, _reply, channel} = WorkerDouble.attach(project.id)

      ref = WorkerDouble.emit_event(channel, %{"run_id" => run.id, "command_id" => command.id})

      assert_reply ref, :ok, %{status: "accepted"}
      assert_receive {:worker_event, envelope}

      assert ContentBoundary.scan_structure(envelope, "worker_event") == :ok
      refute_training_use_keys(envelope, "worker_event")

      assert Enum.sort(Map.keys(envelope)) ==
               Enum.sort(Map.keys(DeliveryProtocolFixtures.event()))
    end

    test "a heartbeat (operational telemetry) carries no credential, email, or field beyond the closed protocol vocabulary [AC-06]",
         %{project: project, run: run} do
      PubSub.subscribe(SddOrchestrator.PubSub, WorkerChannel.topic(project.id))
      {:ok, _reply, channel} = WorkerDouble.attach(project.id)

      ref = WorkerDouble.heartbeat(channel, %{"run_id" => run.id, "last_sequence" => 7})

      assert_reply ref, :ok, %{status: "recorded"}
      assert_receive {:worker_heartbeat, envelope}

      assert ContentBoundary.scan_structure(envelope, "worker_heartbeat") == :ok
      refute_training_use_keys(envelope, "worker_heartbeat")
    end
  end

  describe "model adapter-double routing carries no credential, email, or training-use configuration" do
    setup do
      base =
        Path.join(System.tmp_dir!(), "sdd-routing-agent-#{System.unique_integer([:positive])}")

      root = Path.join(base, "root")
      File.mkdir_p!(root)

      previous = Application.fetch_env(:sdd_orchestrator, :worker_workspace_root)
      Application.put_env(:sdd_orchestrator, :worker_workspace_root, root)
      restore = AgentAdapterDouble.install()

      on_exit(fn ->
        restore.()

        case previous do
          {:ok, value} -> Application.put_env(:sdd_orchestrator, :worker_workspace_root, value)
          :error -> Application.delete_env(:sdd_orchestrator, :worker_workspace_root)
        end

        File.rm_rf!(base)
      end)

      manifest = DeliveryProtocolFixtures.manifest()
      {:ok, _workspace} = Workspace.prepare(manifest)
      {:ok, directory} = Workspace.working_directory(manifest)

      %{manifest: manifest, directory: directory}
    end

    test "a real agent launch hands the provider double no credential, email, or training-use key, and only the approved opaque fields [AC-06]",
         %{manifest: manifest, directory: directory} do
      assert {:ok, _launch} = AgentAdapter.launch(manifest, directory)

      assert [request] = AgentAdapterDouble.requests()
      assert Enum.sort(Map.keys(request)) == [:agent_input, :environment, :thread_ref]

      assert ContentBoundary.scan_structure(request.agent_input, "agent_input") == :ok
      refute_training_use_keys(request, "agent_request")

      assert Enum.sort(Map.keys(request.agent_input)) == Enum.sort(@agent_projected_keys)

      # `run_command` may reach `model_provider` only through `worker_dispatch`
      # (specs/18 Task 4) — the same route this real launch just exercised.
      assert Policy.authorize(:run_command, :worker_dispatch, :model_provider) == :ok
    end
  end

  describe "preview adapter-double routing carries no credential, email, or training-use configuration" do
    setup do
      hosted = DeliveryFixtures.delivery_project_fixture()
      feature = DeliveryFixtures.feature_fixture(hosted.project, hosted.account)

      {:ok, %{run: run, attempt: attempt}} =
        DeliveryStore.commit(
          hosted.workspace,
          hosted.project.id,
          preview_run_steps(hosted.project, feature)
        )

      DeliveryFixtures.verified_completion_fixture(hosted.workspace, hosted.project, run, attempt)

      on_exit(
        PreviewAdapterDouble.install(
          credential_ref: "vault://preview-provider-routing-proof",
          projects: %{hosted.project.id => ["web"]}
        )
      )

      %{authority: hosted.workspace, project: hosted.project, run: run}
    end

    test "a real preview request hands the provider double no credential, email, or training-use key, and only the approved binding fields [AC-06]",
         %{authority: authority, project: project, run: run} do
      PreviewAdapterDouble.script(:ready)

      assert {:ok, _result} = Previews.start(authority, project.id, run)

      assert [request] = PreviewAdapterDouble.requested()
      assert Enum.sort(Map.keys(request)) == Enum.sort(@preview_request_keys)

      assert ContentBoundary.scan_structure(request, "preview_request") == :ok
      refute_training_use_keys(request, "preview_request")

      # `preview_deployment` may reach `preview_provider` only through
      # `preview_deployment` (specs/18 Task 4) — the same route this real
      # request just exercised.
      assert Policy.authorize(:preview_deployment, :preview_deployment, :preview_provider) == :ok
    end
  end

  describe "hosted and device persistence: a device-authority commit leaves no durable hosted copy" do
    setup do
      hosted = DeliveryFixtures.delivery_project_fixture()
      feature = DeliveryFixtures.feature_fixture(hosted.project, hosted.account)

      path =
        Path.join(
          System.tmp_dir!(),
          "delivery-routing-boundary-#{System.unique_integer([:positive])}.dets"
        )

      start_supervised!({Local, path: path})
      on_exit(fn -> File.rm_rf(path) end)

      {:ok, device_workspace} = Devices.establish_workspace()

      %{
        device: %DeviceWorkspace{id: device_workspace.id},
        project: hosted.project,
        feature: feature
      }
    end

    test "a full device commit leaves the hosted run, attempt, activity, and command tables untouched [AC-06]",
         %{device: device, project: project, feature: feature} do
      before = hosted_counts()

      assert {:ok, results} =
               DeliveryStore.commit(device, project.id, device_commit_steps(project, feature))

      assert hosted_counts() == before

      # The records genuinely exist — on the device, not in PostgreSQL.
      assert {:ok, _run} = DeliveryStore.fetch_run(device, project.id, results.run.id)
      refute Repo.get(AgentRun, results.run.id)
      refute Repo.get(RunAttempt, results.attempt.id)
      refute Repo.get(ActivityEntry, results.activity.id)
      refute Repo.get(RunCommand, results.command.id)
    end
  end

  defp assert_same_origin_csp(conn) do
    assert [csp] = get_resp_header(conn, "content-security-policy")

    assert csp =~ "default-src 'self'"
    assert csp =~ "connect-src 'self'"
    assert csp =~ "object-src 'none'"
    assert csp =~ "frame-ancestors 'none'"
    assert csp =~ "base-uri 'self'"
    refute csp =~ "unsafe-inline"
    refute csp =~ "unsafe-eval"
  end

  # Structural absence check for the "provider training-use configuration
  # assertion": no key anywhere in a real recorded provider request names a
  # training-consent, training-use, or data-retention-opt-in configuration —
  # see the moduledoc and `@training_use_keys`.
  defp refute_training_use_keys(value, path) when is_map(value) and not is_struct(value) do
    for {key, nested} <- value do
      name = key |> to_string() |> String.downcase()

      refute name in @training_use_keys,
             "#{path}.#{name} carries a training-use configuration key"

      refute_training_use_keys(nested, "#{path}.#{name}")
    end

    :ok
  end

  defp refute_training_use_keys(value, path) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.each(fn {item, index} -> refute_training_use_keys(item, "#{path}[#{index}]") end)
  end

  defp refute_training_use_keys(_value, _path), do: :ok

  # Mirrors `SddOrchestratorWeb.WorkerChannelTest.enqueue_start/1` (Task 19,
  # read-only reference) so this task drives the same real dispatch path
  # rather than a bespoke shortcut.
  defp enqueue_start(project, feature, run) do
    manifest =
      DeliveryProtocolFixtures.manifest(%{
        "project_id" => project.id,
        "feature_id" => feature.id,
        "run_id" => run.id,
        "attempt_number" => 1
      })

    digest = ExecutionManifest.digest(manifest)
    attempt = DeliveryFixtures.attempt_fixture(run, manifest_digest: digest)

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
        "expected_state_version" => command.expected_state_version,
        "manifest_digest" => digest,
        "payload" => %{"manifest" => ExecutionManifest.to_map(manifest)}
      })

    {command, envelope}
  end

  # Mirrors `SddOrchestratorWeb.PreviewDeploymentTest.run_steps/3` (Task 32,
  # read-only reference), narrowed to one attempt.
  defp preview_run_steps(project, feature) do
    unique = System.unique_integer([:positive])
    digest = DeliveryFixtures.digest("rev-#{unique}")

    [
      {:run,
       {:insert_run,
        %{
          project_id: project.id,
          feature_id: feature.id,
          starting_revision_id: "rev-#{unique}",
          starting_revision_digest: digest,
          approved_slice: "slice-07",
          branch: "sdd/feature-#{unique}"
        }}},
      {:attempt,
       {:insert_attempt,
        %{
          run_id: {:ref, :run, :id},
          attempt_number: 1,
          continuation_reason: "initial",
          effective_revision_id: "rev-#{unique}",
          effective_revision_digest: digest,
          manifest_digest: DeliveryFixtures.digest("manifest-#{unique}"),
          required_checks: DeliveryFixtures.required_check_contract(["mix test"]),
          fence_token: 1
        }}}
    ]
  end

  # Mirrors `SddOrchestrator.Delivery.DeliveryStoreTest.start_steps/2` (Task
  # 18, read-only reference).
  defp device_commit_steps(project, feature) do
    unique = System.unique_integer([:positive])
    digest = DeliveryFixtures.digest("rev-#{unique}")

    [
      {:run,
       {:insert_run,
        %{
          project_id: project.id,
          feature_id: feature.id,
          starting_revision_id: "rev-#{unique}",
          starting_revision_digest: digest,
          approved_slice: "slice-07",
          branch: "sdd/feature-#{unique}"
        }}},
      {:attempt,
       {:insert_attempt,
        %{
          run_id: {:ref, :run, :id},
          attempt_number: 1,
          continuation_reason: "initial",
          effective_revision_id: "rev-#{unique}",
          effective_revision_digest: digest,
          manifest_digest: DeliveryFixtures.digest("manifest-#{unique}"),
          fence_token: 1
        }}},
      {:activity,
       {:append_activity,
        %{
          project_id: project.id,
          feature_id: feature.id,
          run_id: {:ref, :run, :id},
          attempt_id: {:ref, :attempt, :id},
          actor_kind: "system",
          type: "run_started",
          payload: %{}
        }}},
      {:command,
       {:enqueue_command,
        %{
          id: Ecto.UUID.generate(),
          project_id: project.id,
          run_id: {:ref, :run, :id},
          attempt_id: {:ref, :attempt, :id},
          operation: "start",
          expected_state_version: 1,
          manifest_digest: {:ref, :attempt, :manifest_digest}
        }}}
    ]
  end

  defp hosted_counts do
    %{
      runs: Repo.aggregate(AgentRun, :count),
      attempts: Repo.aggregate(RunAttempt, :count),
      activity: Repo.aggregate(ActivityEntry, :count),
      commands: Repo.aggregate(RunCommand, :count)
    }
  end
end
