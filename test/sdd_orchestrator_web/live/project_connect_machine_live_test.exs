defmodule SddOrchestratorWeb.ProjectConnectMachineLiveTest do
  @moduledoc """
  Proof for connecting a machine from the hosted project page (specs/37 Task 4,
  reshaped by specs/40 Task 6).

  A hosted project created normally — no backup package, no restore — must reach
  a connected state from its own page, and every refusal must leave it exactly as
  it was while naming what the owner can do next.

  The folder question now goes to the machine and is answered by a person, so
  the page asks, waits, and then acts on one outcome. Most tests here drive the
  stand-in transport the whole suite is configured with, which answers from a
  real Git repository; the tests that need a particular outcome install the
  transport double and answer the request themselves.
  """
  use SddOrchestratorWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import SddOrchestrator.SelectionSettling, only: [settle: 2]

  alias SddOrchestrator.Devices

  alias SddOrchestrator.Devices.{
    DeviceStore.Local,
    Pairing,
    PairingGuidance,
    PortableRepositoryIdentity,
    WorkerDiscovery
  }

  alias SddOrchestrator.Portability.{
    HostedLocalRepositoryBinding,
    PackageProvenance
  }

  alias SddOrchestrator.Projects.Project
  alias SddOrchestrator.ProjectsFixtures
  alias SddOrchestrator.Repo
  alias SddOrchestrator.RepositorySelection
  alias SddOrchestrator.RepositorySelectionTransportDouble, as: TransportDouble

  setup %{conn: conn} do
    store = store_path()
    on_exit(fn -> File.rm_rf!(Path.dirname(store)) end)
    start_supervised!({Local, path: store})

    {:ok, device_workspace} = Devices.establish_workspace()

    %{conn: conn, account: account} = register_and_log_in_account(%{conn: conn, login: "octo"})
    workspace = ProjectsFixtures.workspace_fixture(account)

    root = git_root()
    on_exit(fn -> File.rm_rf!(root) end)

    repository = init_repo!(Path.join(root, "project-repository"))
    {:ok, repository_id} = PortableRepositoryIdentity.generate(repository)
    project = local_project_fixture(workspace, repository_id, "Local Roadmap")

    point_picker_at(repository)

    %{
      conn: conn,
      workspace: workspace,
      device_workspace: device_workspace,
      project: project,
      repository: repository,
      repository_id: repository_id,
      root: root
    }
  end

  test "connects the single paired machine with no package or restore involved",
       context do
    worker = available_worker_fixture(context.device_workspace)
    assert Repo.get(PackageProvenance, context.project.id) == nil

    {:ok, view, html} = live(context.conn, ~p"/projects/#{context.project.id}/overview")
    assert html =~ ~s(data-worker-connection="disconnected")
    assert html =~ "data-connect-machine"

    # The click asks the machine and nothing more. Nothing is stored while the
    # question is open.
    html = view |> element("[data-connect-machine]") |> render_click()
    assert html =~ "data-selection-waiting"
    assert html =~ "We asked its worker app to open a folder picker."

    html = settle(view, ~s(data-worker-connection="connected"))

    refute html =~ "data-connect-error"
    refute html =~ "data-selection-waiting"

    binding = Repo.get!(HostedLocalRepositoryBinding, context.project.id)
    assert binding.worker_id == worker.id
    assert Repo.get(PackageProvenance, context.project.id) == nil
  end

  test "asks which machine to connect when more than one is paired", context do
    first = available_worker_fixture(context.device_workspace)
    _second = available_worker_fixture(context.device_workspace)

    {:ok, view, _html} = live(context.conn, ~p"/projects/#{context.project.id}/overview")

    html = view |> element("[data-connect-machine]") |> render_click()

    assert html =~ "data-choose-machine"
    assert html =~ "Choose which machine holds this repository"
    assert Repo.get(HostedLocalRepositoryBinding, context.project.id) == nil

    view |> element("[data-machine-option='#{first.id}']") |> render_click()

    settle(view, ~s(data-worker-connection="connected"))
    assert Repo.get!(HostedLocalRepositoryBinding, context.project.id).worker_id == first.id
  end

  test "a repository mismatch keeps the project unconnected with actionable copy",
       context do
    _worker = available_worker_fixture(context.device_workspace)
    other = init_repo!(Path.join(context.root, "different-repository"))
    point_picker_at(other)

    {:ok, view, _html} = live(context.conn, ~p"/projects/#{context.project.id}/overview")
    view |> element("[data-connect-machine]") |> render_click()

    html = settle(view, "data-connect-error")

    assert html =~ ~s(data-worker-connection="disconnected")
    assert html =~ "isn&#39;t this project&#39;s repository"
    assert Repo.get(HostedLocalRepositoryBinding, context.project.id) == nil
  end

  test "a legacy repository identity is refused before any folder is asked for", context do
    _worker = available_worker_fixture(context.device_workspace)
    legacy_id = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    legacy = local_project_fixture(context.workspace, legacy_id, "Legacy Roadmap")

    {:ok, view, _html} = live(context.conn, ~p"/projects/#{legacy.id}/overview")
    html = view |> element("[data-connect-machine]") |> render_click()

    assert html =~ "data-connect-error"
    assert html =~ "tied to its original device workspace"

    # An identity no machine can prove is refused here, so nobody is sent
    # looking for a folder that could never match.
    refute html =~ "data-selection-waiting"
    assert Repo.get(HostedLocalRepositoryBinding, legacy.id) == nil
  end

  test "an unreachable machine is refused and told how to become reachable", context do
    _unreachable = paired_worker_fixture(context.device_workspace)

    {:ok, view, _html} = live(context.conn, ~p"/projects/#{context.project.id}/overview")
    html = view |> element("[data-connect-machine]") |> render_click()

    assert html =~ ~s(data-worker-connection="disconnected")
    assert html =~ "data-connect-error"
    assert html =~ "isn&#39;t reachable right now"
    assert html =~ "Open the worker app"
    refute html =~ "data-selection-waiting"
    assert Repo.get(HostedLocalRepositoryBinding, context.project.id) == nil
  end

  test "a machine with a stale heartbeat is refused before any request is made", context do
    worker =
      context.device_workspace
      |> available_worker_fixture()
      |> stale_worker!()

    on_exit(TransportDouble.install())

    # The list offers this machine on `WorkerDiscovery.status/2` and the connect
    # gate refuses on it, so the pre-check must read the same answer. Reading
    # only attachment would pass it here and refuse it after the owner had
    # already picked a folder.
    assert Devices.worker_available?(worker)
    assert WorkerDiscovery.status([worker]) == :unavailable

    {:ok, view, _html} = live(context.conn, ~p"/projects/#{context.project.id}/overview")
    html = view |> element("[data-connect-machine]") |> render_click()

    assert html =~ "data-connect-error"
    assert html =~ "isn&#39;t reachable right now"
    refute html =~ "data-selection-waiting"

    assert TransportDouble.pushed() == []
    assert Repo.get(HostedLocalRepositoryBinding, context.project.id) == nil
  end

  test "a machine with no attached worker is refused before any folder is asked for", context do
    worker = available_worker_fixture(context.device_workspace)

    # The stand-in that counts a paired worker as attached is off, so
    # availability is read where it really lives: the attachment registry, which
    # holds nothing for this workspace.
    Application.put_env(:sdd_orchestrator, :device_worker_stub, false)
    on_exit(fn -> Application.put_env(:sdd_orchestrator, :device_worker_stub, true) end)
    refute Devices.worker_available?(worker)

    {:ok, view, _html} = live(context.conn, ~p"/projects/#{context.project.id}/overview")
    html = view |> element("[data-connect-machine]") |> render_click()

    assert html =~ "data-connect-error"
    assert html =~ "isn&#39;t reachable right now"
    refute html =~ "data-selection-waiting"
    assert Repo.get(HostedLocalRepositoryBinding, context.project.id) == nil
  end

  test "a machine revoked mid-flow is refused, never silently substituted", context do
    chosen = available_worker_fixture(context.device_workspace)
    _other = available_worker_fixture(context.device_workspace)

    {:ok, view, _html} = live(context.conn, ~p"/projects/#{context.project.id}/overview")
    html = view |> element("[data-connect-machine]") |> render_click()
    assert html =~ "data-choose-machine"

    assert {:ok, _revoked} = Pairing.revoke_worker(chosen)

    html = view |> element("[data-machine-option='#{chosen.id}']") |> render_click()

    assert html =~ "data-connect-error"
    assert html =~ "isn&#39;t paired with your account any more"
    refute html =~ "data-selection-waiting"
    assert Repo.get(HostedLocalRepositoryBinding, context.project.id) == nil
  end

  test "no paired worker offers graphical install and pairing guidance", context do
    {:ok, view, _html} = live(context.conn, ~p"/projects/#{context.project.id}/overview")
    html = view |> element("[data-connect-machine]") |> render_click()

    assert html =~ "data-no-worker-paired"
    assert html =~ "This Mac has no paired worker yet."
    assert html =~ "Open the worker app"
    assert html =~ "Copy the code"
    assert html =~ "the top line that says &quot;Not paired&quot;"

    # This page hands the owner off and renders no pairing field, so it must not
    # promise one by showing the paste step.
    paste = PairingGuidance.paste_step()
    refute html =~ paste.title
    refute html =~ paste.detail
    refute html =~ "data-pairing-form"

    refute html =~ "Terminal"
    refute html =~ "sudo"
    assert Repo.get(HostedLocalRepositoryBinding, context.project.id) == nil
  end

  test "a repeated submit resolves to the same binding, not a second one", context do
    worker = available_worker_fixture(context.device_workspace)

    {:ok, view, _html} = live(context.conn, ~p"/projects/#{context.project.id}/overview")
    view |> element("[data-connect-machine]") |> render_click()
    settle(view, ~s(data-worker-connection="connected"))

    first = Repo.get!(HostedLocalRepositoryBinding, context.project.id)

    {:ok, second_view, _html} = live(context.conn, ~p"/projects/#{context.project.id}/overview")
    render_click(second_view, "connect_machine", %{})
    settle(second_view, ~s(data-worker-connection="connected"))

    assert Repo.aggregate(HostedLocalRepositoryBinding, :count) == 1
    again = Repo.get!(HostedLocalRepositoryBinding, context.project.id)
    assert again.project_id == first.project_id
    assert again.worker_id == worker.id
  end

  describe "what the machine answers" do
    setup context do
      on_exit(TransportDouble.install())

      worker = available_worker_fixture(context.device_workspace)
      {:ok, view, _html} = live(context.conn, ~p"/projects/#{context.project.id}/overview")

      html = view |> element("[data-connect-machine]") |> render_click()
      assert html =~ "data-selection-waiting"

      assert [request] = TransportDouble.pushed()
      assert request.project_id == context.project.id
      assert request.candidates == [%{ref: :project, identity: context.repository_id}]
      assert Repo.get(HostedLocalRepositoryBinding, context.project.id) == nil

      %{request: request, view: view, worker: worker}
    end

    test "a matched folder connects the project", context do
      answer(context, %{
        "outcome" => "selected",
        "folder_name" => "project-repository",
        "matches" => ["project"]
      })

      html = render(context.view)
      assert html =~ ~s(data-worker-connection="connected")
      refute html =~ "data-selection-waiting"

      assert Repo.get!(HostedLocalRepositoryBinding, context.project.id).worker_id ==
               context.worker.id
    end

    test "a folder that is not this repository is refused and nothing is stored", context do
      answer(context, %{"outcome" => "selected", "matches" => []})

      html = render(context.view)
      assert html =~ "data-connect-error"
      assert html =~ "isn&#39;t this project&#39;s repository"
      assert Repo.get(HostedLocalRepositoryBinding, context.project.id) == nil
    end

    test "a folder that is not a Git repository asks for a different one", context do
      answer(context, %{"outcome" => "not_a_git_repository"})

      html = render(context.view)
      assert html =~ "data-connect-error"
      assert html =~ "isn&#39;t a Git repository"
      refute html =~ "data-selection-waiting"
      assert Repo.get(HostedLocalRepositoryBinding, context.project.id) == nil
    end

    test "cancelling returns to the offer and stores nothing", context do
      context.view |> element("[data-cancel-selection]") |> render_click()

      html = render(context.view)
      refute html =~ "data-selection-waiting"
      refute html =~ "data-connect-error"
      assert html =~ "data-connect-machine"
      assert html =~ ~s(data-worker-connection="disconnected")
      assert Repo.get(HostedLocalRepositoryBinding, context.project.id) == nil

      # The worker is told, so its panel closes rather than waiting on a
      # question nobody is listening for.
      assert [cancelled] = TransportDouble.cancelled()
      assert cancelled.id == context.request.id
    end

    test "a request nobody answers offers a retry and stores nothing", context do
      send(context.view.pid, {:repository_selection, context.request.id, :timeout})

      html = render(context.view)
      assert html =~ "data-selection-no-answer"
      assert html =~ "data-retry-connect"
      refute html =~ "data-selection-waiting"
      assert Repo.get(HostedLocalRepositoryBinding, context.project.id) == nil

      # The retry action is the connect action again, so it re-reads the paired
      # set instead of trusting the machine chosen a minute ago.
      html = context.view |> element("[data-retry-connect]") |> render_click()
      assert html =~ "data-selection-waiting"
    end

    test "losing the worker while the panel is open shows the same no-answer state", context do
      stand_in = TransportDouble.worker()
      reference = Process.monitor(stand_in)
      Process.exit(stand_in, :kill)
      assert_receive {:DOWN, ^reference, :process, ^stand_in, :killed}

      # A synchronous call to the request server, so its own monitor message is
      # handled before this test reads the page.
      assert {:error, :not_found} = RepositorySelection.cancel(Ecto.UUID.generate())

      html = render(context.view)
      assert html =~ "data-selection-no-answer"
      assert Repo.get(HostedLocalRepositoryBinding, context.project.id) == nil
    end

    test "an outcome for another request changes nothing", context do
      send(context.view.pid, {:repository_selection, Ecto.UUID.generate(), :timeout})

      html = render(context.view)
      assert html =~ "data-selection-waiting"
      refute html =~ "data-selection-no-answer"

      # The request this page is waiting on is still answerable.
      answer(context, %{"outcome" => "selected", "matches" => ["project"]})
      assert render(context.view) =~ ~s(data-worker-connection="connected")
    end

    # Answers as the attachment the request was pushed to. `answer/2` replies
    # only after the outcome has been sent to the page, so the next render sees
    # it.
    defp answer(context, attrs) do
      attachment = %{
        device_workspace_id: context.device_workspace.id,
        worker_id: context.request.worker_id
      }

      assert :ok =
               RepositorySelection.answer(
                 attachment,
                 Map.put(attrs, "request_id", context.request.id)
               )
    end
  end

  defp point_picker_at(path) do
    Application.put_env(:sdd_orchestrator, :device_worker_stub_folder, path)
    on_exit(fn -> Application.delete_env(:sdd_orchestrator, :device_worker_stub_folder) end)
  end

  defp local_project_fixture(workspace, repository_id, name) do
    %Project{}
    |> Project.changeset(%{
      name: name,
      workspace_id: workspace.id,
      storage_mode: "hosted",
      repository_provider: "local",
      canonical_repository_id: repository_id
    })
    |> Repo.insert!()
  end

  # A worker whose last heartbeat is older than the staleness window. It is
  # still paired and, under the suite's stand-in, still counts as attached, so
  # it is exactly the machine the two readings used to disagree about.
  defp stale_worker!(worker) do
    stale =
      DateTime.utc_now()
      |> DateTime.add(-2 * WorkerDiscovery.staleness_seconds(), :second)
      |> DateTime.truncate(:second)

    worker
    |> Ecto.Changeset.change(last_seen_at: stale)
    |> Repo.update!()
  end

  defp available_worker_fixture(device_workspace) do
    worker = paired_worker_fixture(device_workspace)
    {:ok, worker} = Pairing.mark_seen(worker)
    worker
  end

  defp paired_worker_fixture(device_workspace) do
    {:ok, %{code: code}} = Pairing.start_pairing(device_workspace.id)

    {:ok, %{worker: worker}} =
      Pairing.complete_pairing(code, %{
        os_family: "macos",
        os_major: "26",
        app_version: "1.0.0",
        protocol_version: "1"
      })

    worker
  end

  defp store_path do
    dir =
      Path.join(System.tmp_dir!(), "sdd_connect_machine_#{System.unique_integer([:positive])}")

    Path.join(dir, "store.dets")
  end

  defp git_root do
    Path.join(System.tmp_dir!(), "sdd_connect_machine_repo_#{System.unique_integer([:positive])}")
  end

  defp init_repo!(path) do
    File.mkdir_p!(path)
    git!(path, ["init", "-q"])
    git!(path, ["config", "user.email", "connect-machine@example.test"])
    git!(path, ["config", "user.name", "Connect Machine"])
    File.write!(Path.join(path, "README.md"), "unchanged #{Path.basename(path)}")
    git!(path, ["add", "README.md"])
    git!(path, ["commit", "-q", "-m", "initial"])
    path
  end

  defp git!(path, args) do
    {output, 0} = System.cmd("git", ["-C", path | args], stderr_to_stdout: true)
    String.trim(output)
  end
end
