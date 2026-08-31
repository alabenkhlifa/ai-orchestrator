defmodule SddOrchestratorWeb.HostedLocalRepositoryRunReachabilityTest do
  @moduledoc """
  Task 6 proof: a project connected through this slice reaches a running run.

  This is the defect the slice exists for. `specs/36-local-worker-native-distribution`
  Task 12 drove a real signed worker against a real hosted project and its
  gateway credential exchange was correctly refused `403`, because
  `WorkerGatewayCredentialController` requires a `HostedLocalRepositoryBinding`
  that nothing could create for a normally created project.

  So the assertion order here matters: refuse first, connect through this
  slice's own page, then succeed — and disconnecting must return the exchange to
  refusing.
  """
  use SddOrchestratorWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import SddOrchestrator.SelectionSettling, only: [settle: 2]

  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.{DeviceStore.Local, Pairing, PortableRepositoryIdentity}
  alias SddOrchestrator.Portability.{HostedLocalRepositoryBinding, PackageProvenance}
  alias SddOrchestrator.ProjectAssistant.RepositoryWorkerAvailability
  alias SddOrchestrator.Projects.Project
  alias SddOrchestrator.ProjectsFixtures
  alias SddOrchestrator.Repo
  alias SddOrchestrator.WorkerDouble
  alias SddOrchestratorWeb.WorkerSocket

  @path "/worker/gateway_credentials"

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

    Application.put_env(:sdd_orchestrator, :device_worker_stub_folder, repository)
    on_exit(fn -> Application.delete_env(:sdd_orchestrator, :device_worker_stub_folder) end)

    {worker, credential} = available_worker_fixture(device_workspace)

    %{
      conn: conn,
      workspace: workspace,
      device_workspace: device_workspace,
      project: project,
      repository: repository,
      worker: worker,
      credential: credential
    }
  end

  test "the exchange refuses before connection and succeeds after it", context do
    assert Repo.get(PackageProvenance, context.project.id) == nil
    assert Repo.get(HostedLocalRepositoryBinding, context.project.id) == nil

    refused = exchange(context.project.id, context.credential)
    assert json_response(refused, 403)
    refute RepositoryWorkerAvailability.available?(context.workspace, context.project.id)

    {:ok, view, _html} = live(context.conn, ~p"/projects/#{context.project.id}/overview")
    view |> element("[data-connect-machine]") |> render_click()
    settle(view, ~s(data-worker-connection="connected"))

    issued = exchange(context.project.id, context.credential)
    assert %{"token" => token} = json_response(issued, 200)

    assert {:ok, claims} = WorkerSocket.verify(token)
    assert claims.project_id == context.project.id
    assert claims.worker_id == context.worker.id

    assert RepositoryWorkerAvailability.available?(context.workspace, context.project.id)
    assert Repo.get(PackageProvenance, context.project.id) == nil
  end

  test "the issued credential reaches execution on the project's own run channel",
       context do
    {:ok, view, _html} = live(context.conn, ~p"/projects/#{context.project.id}/overview")
    view |> element("[data-connect-machine]") |> render_click()
    settle(view, ~s(data-worker-connection="connected"))

    assert %{"token" => token} =
             context.project.id
             |> exchange(context.credential)
             |> json_response(200)

    assert {:ok, socket} = WorkerDouble.connect_worker(context.project.id, token: token)

    assert {:ok, _contract, channel} =
             WorkerDouble.join_worker(socket, context.project.id)

    assert channel.topic == "worker:#{context.project.id}"
  end

  test "disconnecting the project returns the exchange to refusing", context do
    {:ok, view, _html} = live(context.conn, ~p"/projects/#{context.project.id}/overview")
    view |> element("[data-connect-machine]") |> render_click()
    settle(view, ~s(data-worker-connection="connected"))

    assert %{"token" => _token} =
             context.project.id
             |> exchange(context.credential)
             |> json_response(200)

    html = view |> element("[data-disconnect-machine]") |> render_click()
    assert html =~ ~s(data-worker-connection="disconnected")

    refused = exchange(context.project.id, context.credential)
    assert json_response(refused, 403)
    refute RepositoryWorkerAvailability.available?(context.workspace, context.project.id)
  end

  test "a second, unconnected project is still refused the same way", context do
    {:ok, unconnected_id} = PortableRepositoryIdentity.generate(context.repository)

    unconnected =
      local_project_fixture(context.workspace, unconnected_id, "Unconnected Roadmap")

    {:ok, view, _html} = live(context.conn, ~p"/projects/#{context.project.id}/overview")
    view |> element("[data-connect-machine]") |> render_click()
    settle(view, ~s(data-worker-connection="connected"))

    assert %{"token" => _token} =
             context.project.id
             |> exchange(context.credential)
             |> json_response(200)

    refused = exchange(unconnected.id, context.credential)
    assert json_response(refused, 403)
    assert Repo.get(HostedLocalRepositoryBinding, unconnected.id) == nil
  end

  # The worker's own exchange is credential-authenticated, not session-scoped, so
  # it runs on a fresh connection rather than the owner's signed-in one.
  defp exchange(project_id, credential) do
    Phoenix.ConnTest.build_conn()
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> credential)
    |> post(@path, %{"project_id" => project_id})
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

  defp available_worker_fixture(device_workspace) do
    {:ok, %{code: code}} = Pairing.start_pairing(device_workspace.id)

    {:ok, %{worker: worker, credential: credential}} =
      Pairing.complete_pairing(code, %{
        os_family: "macos",
        os_major: "26",
        app_version: "1.0.0",
        protocol_version: "1"
      })

    {:ok, worker} = Pairing.mark_seen(worker)
    {worker, credential}
  end

  defp store_path do
    dir =
      Path.join(System.tmp_dir!(), "sdd_run_reachability_#{System.unique_integer([:positive])}")

    Path.join(dir, "store.dets")
  end

  defp git_root do
    Path.join(
      System.tmp_dir!(),
      "sdd_run_reachability_repo_#{System.unique_integer([:positive])}"
    )
  end

  defp init_repo!(path) do
    File.mkdir_p!(path)
    git!(path, ["init", "-q"])
    git!(path, ["config", "user.email", "run-reachability@example.test"])
    git!(path, ["config", "user.name", "Run Reachability"])
    File.write!(Path.join(path, "README.md"), "unchanged")
    git!(path, ["add", "README.md"])
    git!(path, ["commit", "-q", "-m", "initial"])
    path
  end

  defp git!(path, args) do
    {output, 0} = System.cmd("git", ["-C", path | args], stderr_to_stdout: true)
    String.trim(output)
  end
end
