defmodule SddOrchestratorWeb.RepositoryAssessmentLiveTest.Adapter do
  @moduledoc false
  @behaviour SddOrchestrator.RepositoryAssessments.RepositoryMetadataAdapter

  @commit "0123456789abcdef0123456789abcdef01234567"

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  def start_link(_opts),
    do:
      Agent.start_link(
        fn -> %{events: [], overrides: %{}, gate: nil, waiter: nil} end,
        name: __MODULE__
      )

  def install(overrides \\ %{}) do
    Agent.update(__MODULE__, fn _state ->
      %{events: [], overrides: overrides, gate: nil, waiter: nil}
    end)
  end

  def events, do: Agent.get(__MODULE__, & &1.events)

  def change(overrides) do
    Agent.update(__MODULE__, fn state ->
      %{state | overrides: Map.merge(state.overrides, overrides)}
    end)
  end

  @doc """
  Arms a gate that blocks the next `prepare/1` call until `release_gate/0` is
  called. Lets a test observe the caller's waiting state before the adapter
  answers, standing in for a real worker taking a while to respond.
  """
  def hold_gate do
    Agent.update(__MODULE__, fn state -> %{state | gate: :armed} end)
  end

  def release_gate do
    Agent.update(__MODULE__, fn state ->
      if waiter = state.waiter, do: send(waiter, :adapter_gate_released)
      %{state | gate: nil, waiter: nil}
    end)
  end

  defp await_gate do
    caller = self()

    outcome =
      Agent.get_and_update(__MODULE__, fn state ->
        case state.gate do
          :armed -> {:wait, %{state | waiter: caller}}
          _other -> {:go, state}
        end
      end)

    case outcome do
      :go ->
        :ok

      :wait ->
        receive do
          :adapter_gate_released -> :ok
        after
          5_000 -> raise "adapter gate was never released"
        end
    end
  end

  @impl true
  def prepare(request) do
    await_gate()

    case Agent.get(__MODULE__, & &1.overrides[:prepare]) do
      :raise -> die_without_answering()
      _other -> respond(:prepare, request)
    end
  end

  # `RepositoryAssessments.invoke/3` wraps the adapter call in its own
  # `rescue`/`catch`, so a plain `raise` or self-`exit/1` from here is
  # swallowed into an ordinary `{:error, :worker_unavailable}` result rather
  # than a crash: it never proves the "task dies without answering" path.
  # `start_async` links this process to the LiveView, so an untrappable
  # `:kill` would take the LiveView down with it unless that link is removed
  # first (the same order `cancel_async/3` itself uses: unlink, then exit).
  # Removing it here first isolates this forced crash from the LiveView, the
  # same way a real worker crash or connection drop would.
  defp die_without_answering do
    case Process.info(self(), :links) do
      {:links, links} -> Enum.each(links, &Process.unlink/1)
      _no_links -> :ok
    end

    Process.exit(self(), :kill)
  end

  @impl true
  def revalidate(request), do: respond(:revalidate, request)

  defp respond(operation, request) do
    Agent.get_and_update(__MODULE__, fn state ->
      event = {operation, request}
      override = Map.get(state.overrides, operation, %{})

      result =
        case override do
          {:error, reason} ->
            {:error, reason}

          fields when is_map(fields) ->
            {:ok,
             Map.merge(
               %{
                 repository_provider: request.repository_provider,
                 repository_id: request.repository_id,
                 root: request.selected_root,
                 commit: @commit
               },
               fields
             )}
        end

      {result, %{state | events: state.events ++ [event]}}
    end)
  end
end

defmodule SddOrchestratorWeb.RepositoryAssessmentLiveTest do
  use SddOrchestratorWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias SddOrchestrator.AccountsFixtures
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.{DeviceStore.Local, Pairing, WorkerDiscovery}
  alias SddOrchestrator.HostedAccess.{SessionCookie, Sessions}
  alias SddOrchestrator.HostedAccessFixtures
  alias SddOrchestrator.ParticipationFixtures
  alias SddOrchestrator.Portability.{HostedLocalRepositoryBinding, HostedLocalRepositoryBindings}
  alias SddOrchestrator.Projects
  alias SddOrchestrator.Projects.Project
  alias SddOrchestrator.ProjectsFixtures
  alias SddOrchestrator.Repo

  alias SddOrchestrator.RepositoryAssessments.{
    AssessmentStore,
    BindingStore,
    RepositoryAssessment,
    RepositoryMetadataAdapter
  }

  alias SddOrchestrator.RepositoryMetadata
  alias SddOrchestrator.RepositoryMetadata.MetadataRequest
  alias SddOrchestrator.RepositoryMetadataTransportDouble, as: TransportDouble

  alias SddOrchestratorWeb.RepositoryAssessmentLive
  alias SddOrchestratorWeb.RepositoryAssessmentLiveTest.Adapter

  setup %{conn: conn} do
    store_path =
      Path.join(
        System.tmp_dir!(),
        "repository-assessment-live-#{System.unique_integer([:positive])}/store.dets"
      )

    start_supervised!({Local, path: store_path})
    start_supervised!(Adapter)
    :ok = BindingStore.reset()
    Adapter.install()

    previous_adapter = Application.get_env(:sdd_orchestrator, :repository_metadata_adapter)
    Application.put_env(:sdd_orchestrator, :repository_metadata_adapter, Adapter)

    on_exit(fn ->
      File.rm_rf!(Path.dirname(store_path))

      if previous_adapter do
        Application.put_env(:sdd_orchestrator, :repository_metadata_adapter, previous_adapter)
      else
        Application.delete_env(:sdd_orchestrator, :repository_metadata_adapter)
      end
    end)

    %{conn: owner_conn, account: account} = register_and_log_in_account(%{conn: conn})
    workspace = ProjectsFixtures.workspace_fixture(account)
    hosted_project = ProjectsFixtures.registered_project(workspace, name: "Hosted assessment")

    {:ok, device_workspace} = Devices.establish_workspace()

    {:ok, device_project} =
      Devices.register_project(%{
        name: "Device assessment",
        repository_fingerprint: ProjectsFixtures.local_repository_metadata().fingerprint,
        status: "connected"
      })

    worker = reachable_worker(device_workspace.id)

    %{
      account: account,
      device_project: device_project,
      device_workspace: device_workspace,
      hosted_project: hosted_project,
      owner_conn: owner_conn,
      worker: worker,
      workspace: workspace
    }
  end

  test "the hosted owner confirms the exact disclosed contract before metadata and starts separately",
       context do
    project = hosted_local_project(context)
    path = ~p"/projects/#{project.id}/assessment"
    {:ok, view, html} = live(context.owner_conn, path)

    assert html =~ ~s(data-screen="repository-assessment")
    assert html =~ ~s(data-assessment-stage="disclosure")
    assert html =~ "No repository metadata call or scan command is issued before confirmation."
    refute html =~ ~s(maxlength="255")
    assert Adapter.events() == []
    assert AssessmentStore.count(hosted_authority(context), project.id) == 0

    for item <- RepositoryAssessmentLive.disclosure_items() do
      assert has_element?(view, ~s([data-disclosure-field="#{item.key}"]), item.title)
      assert render(view) =~ item.body
    end

    root = String.duplicate("a", 300)

    view
    |> form("#assessment-binding-form",
      assessment: %{
        selected_root: root,
        worker_ref: context.worker.id,
        confirmed: "true"
      }
    )
    |> render_submit()

    render_async(view)

    assert [{:prepare, request}] = Adapter.events()
    assert request.selected_root == root
    assert request.disclosure_digest == RepositoryAssessmentLive.disclosure_digest()
    assert has_element?(view, "[data-verified-binding]")

    assert view |> element(~s([data-binding-field="repository"])) |> render() =~
             "Local repository for #{project.name}"

    assert view |> element(~s([data-binding-field="root"])) |> render() =~ root

    assert view |> element(~s([data-binding-field="commit"])) |> render() =~
             "0123456789abcdef0123456789abcdef01234567"

    assert AssessmentStore.count(hosted_authority(context), project.id) == 0

    view |> form("#assessment-start-form") |> render_submit()

    assert Enum.map(Adapter.events(), &elem(&1, 0)) == [:prepare, :revalidate]
    refute Enum.any?(Adapter.events(), fn {operation, _request} -> operation == :scan end)
    assert has_element?(view, "[data-assessment-pending]")
    assert view |> element("[data-assessment-state]") |> render() =~ "Pending scan"
    assert AssessmentStore.count(hosted_authority(context), project.id) == 1
  end

  test "the device owner uses device-authoritative storage and creates no hosted row", context do
    hosted_count = Repo.aggregate(RepositoryAssessment, :count)
    path = ~p"/local/projects/#{context.device_project.id}/assessment"
    {:ok, view, html} = live(context.conn, path)

    assert html =~ "Processing boundary"
    refute has_element?(view, "[data-project-nav]")
    assert Adapter.events() == []

    confirm_binding(view, context.worker.id)
    assert has_element?(view, "[data-verified-binding]")
    view |> form("#assessment-start-form") |> render_submit()

    assert has_element?(view, "[data-assessment-pending]")
    assert Devices.repository_assessment_count(context.device_project.id) == 1
    assert Repo.aggregate(RepositoryAssessment, :count) == hosted_count
  end

  test "participants, outsiders, unknown projects, and accountless hosted visitors fail closed",
       context do
    participant = HostedAccessFixtures.hosted_identity_fixture()
    ParticipationFixtures.participant_fixture(context.hosted_project, participant.hosted_identity)

    assert {:error, {:live_redirect, %{to: "/projects"}}} =
             context.conn
             |> log_in_hosted(participant.hosted_identity)
             |> live(~p"/projects/#{context.hosted_project.id}/assessment")

    outsider = AccountsFixtures.account_fixture()

    assert {:error, {:live_redirect, %{to: "/projects"}}} =
             context.conn
             |> log_in_account(outsider)
             |> live(~p"/projects/#{context.hosted_project.id}/assessment")

    assert {:error, {:live_redirect, %{to: "/projects"}}} =
             live(context.owner_conn, ~p"/projects/#{Ecto.UUID.generate()}/assessment")

    assert {:error, {:live_redirect, %{to: "/projects"}}} =
             live(context.conn, ~p"/projects/#{context.hosted_project.id}/assessment")

    assert Adapter.events() == []
  end

  test "the assessment screen opens for a project whose repository is on the owner's Mac",
       context do
    project = hosted_local_project(context)

    assert {:ok, _view, html} =
             live(context.owner_conn, ~p"/projects/#{project.id}/assessment")

    assert html =~ ~s(data-screen="repository-assessment")
    assert html =~ ~s(data-assessment-stage="disclosure")
    assert Adapter.events() == []
  end

  test "a hosted project with no reachable repository still redirects away", context do
    unreachable = hosted_local_project(context)

    HostedLocalRepositoryBinding
    |> Repo.get!(unreachable.id)
    |> Repo.delete!()

    assert {:error, {:live_redirect, %{to: "/projects"}}} =
             live(context.owner_conn, ~p"/projects/#{unreachable.id}/assessment")

    context.hosted_project.repository_connection
    |> Ecto.Changeset.change(state: "disconnected")
    |> Repo.update!()

    assert {:error, {:live_redirect, %{to: "/projects"}}} =
             live(context.owner_conn, ~p"/projects/#{context.hosted_project.id}/assessment")

    assert Adapter.events() == []
  end

  test "a repository on the owner's Mac is named the way the device route names one", context do
    project = hosted_local_project(context)

    {:ok, view, _html} = live(context.owner_conn, ~p"/projects/#{project.id}/assessment")
    confirm_binding(view, context.worker.id)

    assert view |> element(~s([data-binding-field="repository"])) |> render() =~
             "Local repository for #{project.name}"

    refute render(view) =~ "Connected repository"
  end

  test "a connected provider repository and the device route keep their own labels", context do
    {:ok, hosted_view, _html} =
      live(context.owner_conn, ~p"/projects/#{context.hosted_project.id}/assessment")

    # A GitHub project's repository is not one a worker can verify locally, so it
    # is named on the not-on-a-Mac disclosure state, not the verified binding.
    assert hosted_view |> element("[data-repository-name]") |> render() =~ "octo/example"

    {:ok, device_view, _html} =
      live(context.conn, ~p"/local/projects/#{context.device_project.id}/assessment")

    confirm_binding(device_view, context.worker.id)

    assert device_view |> element(~s([data-binding-field="repository"])) |> render() =~
             "Local repository for Device assessment"
  end

  test "an unreachable Mac opens the screen, offers no start, and changes nothing", context do
    project = hosted_local_project(context)
    before = Repo.get!(Project, project.id)
    binding_before = Repo.get!(HostedLocalRepositoryBinding, project.id)
    unattach(context.worker)

    assert {:ok, %{binding: %HostedLocalRepositoryBinding{}, state: :temporarily_unavailable}} =
             HostedLocalRepositoryBindings.connection_state(context.workspace, project.id)

    {:ok, view, html} = live(context.owner_conn, ~p"/projects/#{project.id}/assessment")

    assert html =~ ~s(data-assessment-stage="disclosure")

    assert view |> element("[data-no-workers]") |> render() =~
             RepositoryAssessmentLive.worker_unavailable_message()

    assert has_element?(view, "[data-confirm-boundary][disabled]")
    refute has_element?(view, "[data-start-assessment]")

    assert Adapter.events() == []
    assert AssessmentStore.count(hosted_authority(context), project.id) == 0
    assert Repo.get!(Project, project.id) == before
    assert Repo.get!(HostedLocalRepositoryBinding, project.id) == binding_before
  end

  test "a person who does not own the Mac project is redirected away", context do
    project = hosted_local_project(context)
    outsider = AccountsFixtures.account_fixture()

    assert {:error, {:live_redirect, %{to: "/projects"}}} =
             context.conn
             |> log_in_account(outsider)
             |> live(~p"/projects/#{project.id}/assessment")

    assert Adapter.events() == []
  end

  test "unknown device projects fail closed without a metadata call", context do
    assert {:error, {:live_redirect, %{to: "/onboarding/local"}}} =
             live(context.conn, ~p"/local/projects/#{Ecto.UUID.generate()}/assessment")

    assert Adapter.events() == []
  end

  test "unavailable and stale bindings show safe actionable messages and persist nothing",
       context do
    project = hosted_local_project(context)

    {:ok, unavailable_view, _html} =
      live(context.owner_conn, ~p"/projects/#{project.id}/assessment")

    Adapter.install(%{prepare: {:error, :repository_mismatch}})
    confirm_binding(unavailable_view, context.worker.id)

    unavailable_html = render(unavailable_view)
    assert unavailable_html =~ "did not verify this project&#39;s connected repository"
    refute unavailable_html =~ ":repository_mismatch"
    refute unavailable_html =~ "/Users/"
    assert AssessmentStore.count(hosted_authority(context), project.id) == 0

    Adapter.install()

    {:ok, stale_view, _html} =
      live(context.owner_conn, ~p"/projects/#{project.id}/assessment")

    confirm_binding(stale_view, context.worker.id)
    Adapter.change(%{revalidate: %{commit: String.duplicate("d", 40)}})
    stale_view |> form("#assessment-start-form") |> render_submit()

    stale_html = render(stale_view)
    assert stale_html =~ "changed or expired"
    assert has_element?(stale_view, "[data-binding-form]")
    refute stale_html =~ ":stale"
    assert AssessmentStore.count(hosted_authority(context), project.id) == 0
  end

  test "assessment navigation is owner-only and the device dashboard exposes its local route",
       context do
    {:ok, hosted_view, _html} =
      live(context.owner_conn, ~p"/projects/#{context.hosted_project.id}/assessment")

    assert has_element?(
             hosted_view,
             ~s([data-nav-destination="assessment"][href="/projects/#{context.hosted_project.id}/assessment"][aria-current="page"])
           )

    {:ok, device_view, _html} =
      live(context.conn, ~p"/local/projects/#{context.device_project.id}")

    assert has_element?(
             device_view,
             ~s([data-open-assessment][href="/local/projects/#{context.device_project.id}/assessment"])
           )
  end

  test "confirming shows the waiting stage before the worker answers, then the binding once it does",
       context do
    project = hosted_local_project(context)
    path = ~p"/projects/#{project.id}/assessment"
    {:ok, view, _html} = live(context.owner_conn, path)

    Adapter.hold_gate()

    view
    |> form("#assessment-binding-form",
      assessment: %{selected_root: ".", worker_ref: context.worker.id, confirmed: "true"}
    )
    |> render_submit()

    assert has_element?(view, "[data-preparing]")
    assert has_element?(view, "[data-stop-preparing]")
    refute has_element?(view, "[data-verified-binding]")
    assert AssessmentStore.count(hosted_authority(context), project.id) == 0

    Adapter.release_gate()
    render_async(view)

    assert has_element?(view, "[data-verified-binding]")
    refute has_element?(view, "[data-preparing]")
    assert AssessmentStore.count(hosted_authority(context), project.id) == 0
  end

  test "stopping the wait cancels the task, returns to disclosure, and persists nothing",
       context do
    # The device route so the persisted-nothing check reads the local device
    # store (`Devices.repository_assessment_count/1`) instead of Postgres.
    # `cancel_async/3` kills the waiting task mid-flight, and that kill can
    # tear down the shared sandbox connection the task was borrowing; reading
    # Postgres again afterward in the same test then fails with an ownership
    # error unrelated to the product behavior under test.
    path = ~p"/local/projects/#{context.device_project.id}/assessment"
    {:ok, view, _html} = live(context.conn, path)

    Adapter.hold_gate()

    view
    |> form("#assessment-binding-form",
      assessment: %{selected_root: ".", worker_ref: context.worker.id, confirmed: "true"}
    )
    |> render_submit()

    assert has_element?(view, "[data-preparing]")

    view |> element("[data-stop-preparing]") |> render_click()

    # `cancel_async/3` kills the task; the stage change arrives back through
    # `handle_async/3` on its own message, separately from this click's
    # reply. `render_async/1` waits on a fresh monitor taken out *after* the
    # task pid is already gone, which races the LiveView's own older monitor
    # for that same pid, so it is not a reliable wait for a cancellation
    # (unlike a normal completion, where the result is sent before the task
    # process exits). Poll the rendered stage instead.
    assert await_disclosure_stage(view)

    assert render(view) =~ "The wait was stopped."
    assert has_element?(view, "[data-confirm-boundary]:not([disabled])")
    assert Devices.repository_assessment_count(context.device_project.id) == 0
    assert BindingStore.count() == 0
  end

  test "a task that dies without answering resolves to disclosure with a retryable message",
       context do
    project = hosted_local_project(context)
    path = ~p"/projects/#{project.id}/assessment"
    {:ok, view, _html} = live(context.owner_conn, path)

    Adapter.install(%{prepare: :raise})

    view
    |> form("#assessment-binding-form",
      assessment: %{selected_root: ".", worker_ref: context.worker.id, confirmed: "true"}
    )
    |> render_submit()

    render_async(view)

    assert has_element?(view, ~s([data-screen="repository-assessment"][data-assessment-stage="disclosure"]))
    assert render(view) =~ "The wait could not finish."
    assert has_element?(view, "[data-confirm-boundary]:not([disabled])")
    assert AssessmentStore.count(hosted_authority(context), project.id) == 0
    assert BindingStore.count() == 0
  end

  describe "AC-10: a repository that is not on a Mac cannot be confirmed" do
    test "a GitHub-connected project is named and refused before any confirmation is offered",
         context do
      {:ok, view, html} =
        live(context.owner_conn, ~p"/projects/#{context.hosted_project.id}/assessment")

      assert html =~ ~s(data-assessment-stage="disclosure")
      assert has_element?(view, "[data-repository-not-verifiable]")
      assert view |> element("[data-repository-name]") |> render() =~ "octo/example"
      refute has_element?(view, "#assessment-binding-form")
      refute has_element?(view, "[data-confirm-boundary]")
      assert Adapter.events() == []
    end
  end

  # AC-02: the verified-binding readout already renders whatever `@preparation`
  # holds; this proves it holds a real worker's answer, reached through the real
  # adapter (`RepositoryMetadataAdapter.Worker`) and the scripted transport
  # double, not the fake `Adapter` this file installs for every other test.
  describe "AC-02: the verified binding renders a real worker's answer" do
    test "prepare_binding through the live worker adapter renders the worker's own identity, root, and commit",
         context do
      previous_adapter = Application.get_env(:sdd_orchestrator, :repository_metadata_adapter)

      Application.put_env(
        :sdd_orchestrator,
        :repository_metadata_adapter,
        RepositoryMetadataAdapter.Worker
      )

      on_exit(fn ->
        if previous_adapter do
          Application.put_env(:sdd_orchestrator, :repository_metadata_adapter, previous_adapter)
        else
          Application.delete_env(:sdd_orchestrator, :repository_metadata_adapter)
        end
      end)

      # Installs `TransportDouble` as `:repository_metadata_transport` and
      # restores whatever was configured before, the same pattern
      # `LiveAdapterTest` and `WorkerTest` use for this same double.
      on_exit(TransportDouble.install())

      project = hosted_local_project(context)
      # Deliberately not "." (what every other test in this file submits) and
      # not the fake `Adapter`'s hardcoded commit, so a passing assertion below
      # could only be satisfied by this scripted answer actually reaching the
      # screen through the real adapter and the double, not by the fake
      # `Adapter` still being wired in.
      root = "worker-verified/root"
      commit = String.duplicate("f", 40)

      {:ok, view, _html} = live(context.owner_conn, ~p"/projects/#{project.id}/assessment")

      before_count = length(TransportDouble.pushed())

      view
      |> form("#assessment-binding-form",
        assessment: %{selected_root: root, worker_ref: context.worker.id, confirmed: "true"}
      )
      |> render_submit()

      request = wait_for_next_pushed(before_count)

      attachment = %{
        device_workspace_id: request.device_workspace_id,
        worker_id: request.worker_id
      }

      assert :ok =
               RepositoryMetadata.answer(attachment, %{
                 "request_id" => request.id,
                 "outcome" => "metadata",
                 "repository_provider" => request.repository_provider,
                 "repository_id" => request.repository_id,
                 "root" => root,
                 "commit" => commit
               })

      render_async(view)

      assert has_element?(view, "[data-verified-binding]")

      assert view |> element(~s([data-binding-field="identity"])) |> render() =~
               "#{project.repository_provider}:#{project.canonical_repository_id}"

      assert view |> element(~s([data-binding-field="root"])) |> render() =~ root
      assert view |> element(~s([data-binding-field="commit"])) |> render() =~ commit

      # The fake `Adapter` this file installs for every other test never saw a
      # call: the real pipeline (LiveView -> prepare_binding/4 ->
      # RepositoryMetadataAdapter.Worker -> RepositoryMetadata.inspect/1 -> the
      # transport double) is what answered.
      assert Adapter.events() == []
    end
  end

  defp wait_for_next_pushed(before_count) do
    assert wait_until(fn -> length(TransportDouble.pushed()) > before_count end)
    %MetadataRequest{} = List.last(TransportDouble.pushed())
  end

  defp wait_until(check, attempts \\ 100) do
    cond do
      check.() -> true
      attempts <= 0 -> false
      true -> wait_again(check, attempts)
    end
  end

  defp wait_again(check, attempts) do
    Process.sleep(10)
    wait_until(check, attempts - 1)
  end

  defp await_disclosure_stage(view, attempts \\ 100)

  defp await_disclosure_stage(_view, 0), do: flunk("view did not return to the disclosure stage")

  defp await_disclosure_stage(view, attempts) do
    if has_element?(
         view,
         ~s([data-screen="repository-assessment"][data-assessment-stage="disclosure"])
       ) do
      true
    else
      Process.sleep(10)
      await_disclosure_stage(view, attempts - 1)
    end
  end

  defp confirm_binding(view, worker_id, root \\ ".") do
    view
    |> form("#assessment-binding-form",
      assessment: %{selected_root: root, worker_ref: worker_id, confirmed: "true"}
    )
    |> render_submit()

    render_async(view)
  end

  # A hosted project whose repository is a Git repository on the owner's Mac: no
  # GitHub connection, and the worker binding registration writes for it.
  defp hosted_local_project(context) do
    attempt =
      ProjectsFixtures.device_attempt_ready_for_hosted(
        context.device_workspace,
        context.workspace,
        worker_id: context.worker.id
      )

    {:ok, project} = Projects.register_project(context.workspace, attempt)
    project
  end

  # The Mac stops reporting in. Registration binds only an available worker, so a
  # bound Mac cannot start unattached; it goes stale afterwards, as one does when
  # it sleeps or shuts down.
  defp unattach(worker) do
    stale = DateTime.add(DateTime.utc_now(), -(WorkerDiscovery.staleness_seconds() + 60), :second)

    worker
    |> Ecto.Changeset.change(last_seen_at: DateTime.truncate(stale, :second))
    |> Repo.update!()
  end

  defp hosted_authority(context), do: {:hosted, context.account.id}

  defp reachable_worker(device_workspace_id) do
    {:ok, %{code: code}} = Pairing.start_pairing(device_workspace_id)

    {:ok, %{worker: worker}} =
      Pairing.complete_pairing(code, %{
        os_family: "macos",
        os_major: "26",
        app_version: "1.0.0",
        protocol_version: "1"
      })

    {:ok, worker} = Pairing.mark_seen(worker)
    worker
  end

  defp log_in_hosted(conn, hosted_identity) do
    {:ok, _session, cookie} = Sessions.create(hosted_identity, %{})

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(SessionCookie.session_key(), cookie.value)
  end
end
