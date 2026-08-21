defmodule SddOrchestratorWeb.RepositoryAssessmentLiveTest.Adapter do
  @moduledoc false
  @behaviour SddOrchestrator.RepositoryAssessments.RepositoryMetadataAdapter

  @commit "0123456789abcdef0123456789abcdef01234567"

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  def start_link(_opts),
    do: Agent.start_link(fn -> %{events: [], overrides: %{}} end, name: __MODULE__)

  def install(overrides \\ %{}) do
    Agent.update(__MODULE__, fn _state -> %{events: [], overrides: overrides} end)
  end

  def events, do: Agent.get(__MODULE__, & &1.events)

  def change(overrides) do
    Agent.update(__MODULE__, fn state ->
      %{state | overrides: Map.merge(state.overrides, overrides)}
    end)
  end

  @impl true
  def prepare(request), do: respond(:prepare, request)

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
  alias SddOrchestrator.Devices.{DeviceStore.Local, Pairing}
  alias SddOrchestrator.HostedAccess.{SessionCookie, Sessions}
  alias SddOrchestrator.HostedAccessFixtures
  alias SddOrchestrator.ParticipationFixtures
  alias SddOrchestrator.ProjectsFixtures
  alias SddOrchestrator.Repo

  alias SddOrchestrator.RepositoryAssessments.{
    AssessmentStore,
    BindingStore,
    RepositoryAssessment
  }

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
      worker: worker
    }
  end

  test "the hosted owner confirms the exact disclosed contract before metadata and starts separately",
       context do
    path = ~p"/projects/#{context.hosted_project.id}/assessment"
    {:ok, view, html} = live(context.owner_conn, path)

    assert html =~ ~s(data-screen="repository-assessment")
    assert html =~ ~s(data-assessment-stage="disclosure")
    assert html =~ "No repository metadata call or scan command is issued before confirmation."
    refute html =~ ~s(maxlength="255")
    assert Adapter.events() == []
    assert AssessmentStore.count(hosted_authority(context), context.hosted_project.id) == 0

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

    assert [{:prepare, request}] = Adapter.events()
    assert request.selected_root == root
    assert request.disclosure_digest == RepositoryAssessmentLive.disclosure_digest()
    assert has_element?(view, "[data-verified-binding]")
    assert view |> element(~s([data-binding-field="repository"])) |> render() =~ "octo/example"
    assert view |> element(~s([data-binding-field="root"])) |> render() =~ root

    assert view |> element(~s([data-binding-field="commit"])) |> render() =~
             "0123456789abcdef0123456789abcdef01234567"

    assert AssessmentStore.count(hosted_authority(context), context.hosted_project.id) == 0

    view |> form("#assessment-start-form") |> render_submit()

    assert Enum.map(Adapter.events(), &elem(&1, 0)) == [:prepare, :revalidate]
    refute Enum.any?(Adapter.events(), fn {operation, _request} -> operation == :scan end)
    assert has_element?(view, "[data-assessment-pending]")
    assert view |> element("[data-assessment-state]") |> render() =~ "Pending scan"
    assert AssessmentStore.count(hosted_authority(context), context.hosted_project.id) == 1
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

  test "unknown device projects fail closed without a metadata call", context do
    assert {:error, {:live_redirect, %{to: "/onboarding/local"}}} =
             live(context.conn, ~p"/local/projects/#{Ecto.UUID.generate()}/assessment")

    assert Adapter.events() == []
  end

  test "unavailable and stale bindings show safe actionable messages and persist nothing",
       context do
    {:ok, unavailable_view, _html} =
      live(context.owner_conn, ~p"/projects/#{context.hosted_project.id}/assessment")

    Adapter.install(%{prepare: {:error, :repository_mismatch}})
    confirm_binding(unavailable_view, context.worker.id)

    unavailable_html = render(unavailable_view)
    assert unavailable_html =~ "did not verify this project&#39;s connected repository"
    refute unavailable_html =~ ":repository_mismatch"
    refute unavailable_html =~ "/Users/"
    assert AssessmentStore.count(hosted_authority(context), context.hosted_project.id) == 0

    Adapter.install()

    {:ok, stale_view, _html} =
      live(context.owner_conn, ~p"/projects/#{context.hosted_project.id}/assessment")

    confirm_binding(stale_view, context.worker.id)
    Adapter.change(%{revalidate: %{commit: String.duplicate("d", 40)}})
    stale_view |> form("#assessment-start-form") |> render_submit()

    stale_html = render(stale_view)
    assert stale_html =~ "changed or expired"
    assert has_element?(stale_view, "[data-binding-form]")
    refute stale_html =~ ":stale"
    assert AssessmentStore.count(hosted_authority(context), context.hosted_project.id) == 0
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

  defp confirm_binding(view, worker_id, root \\ ".") do
    view
    |> form("#assessment-binding-form",
      assessment: %{selected_root: root, worker_ref: worker_id, confirmed: "true"}
    )
    |> render_submit()
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
