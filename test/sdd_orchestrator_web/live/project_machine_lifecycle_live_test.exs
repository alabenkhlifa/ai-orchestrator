defmodule SddOrchestratorWeb.ProjectMachineLifecycleLiveTest do
  @moduledoc """
  Task 5 proof for disconnecting a project and moving it to another machine.

  A connected project must not be stuck on one machine, undoing the link must
  touch nothing but the routing, and a failed replacement must leave the previous
  machine authoritative.
  """
  use SddOrchestratorWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import SddOrchestrator.SelectionSettling, only: [settle: 2, settled: 1]

  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.{DeviceStore.Local, Pairing, PortableRepositoryIdentity}
  alias SddOrchestrator.Portability.HostedLocalRepositoryBinding
  alias SddOrchestrator.Projects.Project
  alias SddOrchestrator.ProjectsFixtures
  alias SddOrchestrator.Repo
  alias SddOrchestrator.SpecificationFixtures
  alias SddOrchestrator.SpecificationStore

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
    _specification = SpecificationFixtures.hosted_specification(workspace, project)

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

  test "disconnect removes only the routing and returns the page to not connected",
       context do
    _worker = available_worker_fixture(context.device_workspace)
    before_repository = git_snapshot(context.repository)
    before_project = Repo.get!(Project, context.project.id)

    assert {:ok, before_specifications} =
             SpecificationStore.current_snapshot(context.workspace, context.project.id)

    {:ok, view, _html} = live(context.conn, ~p"/projects/#{context.project.id}/overview")
    view |> element("[data-connect-machine]") |> render_click()
    settle(view, ~s(data-worker-connection="connected"))

    html = view |> element("[data-disconnect-machine]") |> render_click()

    assert html =~ ~s(data-worker-connection="disconnected")
    assert html =~ "No machine connected yet"
    refute html =~ "data-disconnect-machine"
    assert Repo.get(HostedLocalRepositoryBinding, context.project.id) == nil

    assert Repo.get!(Project, context.project.id) == before_project
    assert git_snapshot(context.repository) == before_repository

    assert {:ok, after_specifications} =
             SpecificationStore.current_snapshot(context.workspace, context.project.id)

    assert after_specifications == before_specifications
  end

  test "a repeated disconnect succeeds instead of erroring", context do
    _worker = available_worker_fixture(context.device_workspace)

    {:ok, view, _html} = live(context.conn, ~p"/projects/#{context.project.id}/overview")
    view |> element("[data-connect-machine]") |> render_click()
    settle(view, ~s(data-worker-connection="connected"))

    html = view |> element("[data-disconnect-machine]") |> render_click()
    assert html =~ ~s(data-worker-connection="disconnected")

    html = render_click(view, "disconnect_machine", %{})

    assert html =~ ~s(data-worker-connection="disconnected")
    refute html =~ "data-connect-error"
    assert Repo.get(HostedLocalRepositoryBinding, context.project.id) == nil
  end

  test "a different machine that proves the same repository replaces the binding",
       context do
    first = available_worker_fixture(context.device_workspace)

    {:ok, view, _html} = live(context.conn, ~p"/projects/#{context.project.id}/overview")
    view |> element("[data-connect-machine]") |> render_click()
    settle(view, ~s(data-worker-connection="connected"))
    assert Repo.get!(HostedLocalRepositoryBinding, context.project.id).worker_id == first.id

    second = available_worker_fixture(context.device_workspace)

    html = view |> element("[data-connect-machine]") |> render_click()
    assert html =~ "data-choose-machine"

    # The page was already connected to the first machine, so what this click
    # waits on is the page no longer asking, not the connected state.
    view |> element("[data-machine-option='#{second.id}']") |> render_click()
    assert settled(view) =~ ~s(data-worker-connection="connected")

    assert Repo.aggregate(HostedLocalRepositoryBinding, :count) == 1

    binding = Repo.get!(HostedLocalRepositoryBinding, context.project.id)
    assert binding.worker_id == second.id
    refute binding.worker_id == first.id
  end

  test "a failed replacement leaves the previous machine authoritative", context do
    first = available_worker_fixture(context.device_workspace)
    before_repository = git_snapshot(context.repository)

    {:ok, view, _html} = live(context.conn, ~p"/projects/#{context.project.id}/overview")
    view |> element("[data-connect-machine]") |> render_click()
    settle(view, ~s(data-worker-connection="connected"))
    original = Repo.get!(HostedLocalRepositoryBinding, context.project.id)
    assert original.worker_id == first.id

    second = available_worker_fixture(context.device_workspace)
    point_picker_at(init_repo!(Path.join(context.root, "different-repository")))

    html = view |> element("[data-connect-machine]") |> render_click()
    assert html =~ "data-choose-machine"

    view |> element("[data-machine-option='#{second.id}']") |> render_click()
    html = settle(view, "data-connect-error")

    assert html =~ "isn&#39;t this project&#39;s repository"
    assert html =~ ~s(data-worker-connection="connected")

    assert Repo.aggregate(HostedLocalRepositoryBinding, :count) == 1
    assert Repo.get!(HostedLocalRepositoryBinding, context.project.id) == original
    assert git_snapshot(context.repository) == before_repository
  end

  test "an unreachable replacement machine leaves the previous binding intact", context do
    first = available_worker_fixture(context.device_workspace)

    {:ok, view, _html} = live(context.conn, ~p"/projects/#{context.project.id}/overview")
    view |> element("[data-connect-machine]") |> render_click()
    settle(view, ~s(data-worker-connection="connected"))
    original = Repo.get!(HostedLocalRepositoryBinding, context.project.id)

    unreachable = paired_worker_fixture(context.device_workspace)

    view |> element("[data-connect-machine]") |> render_click()
    view |> element("[data-machine-option='#{unreachable.id}']") |> render_click()
    html = settle(view, "data-connect-error")

    assert html =~ "isn&#39;t reachable right now"
    assert Repo.get!(HostedLocalRepositoryBinding, context.project.id) == original
    assert Repo.get!(HostedLocalRepositoryBinding, context.project.id).worker_id == first.id
  end

  test "a connected page offers both moving the machine and disconnecting", context do
    _worker = available_worker_fixture(context.device_workspace)

    {:ok, view, _html} = live(context.conn, ~p"/projects/#{context.project.id}/overview")
    view |> element("[data-connect-machine]") |> render_click()
    html = settle(view, ~s(data-worker-connection="connected"))

    assert html =~ "Connect a different machine"
    assert html =~ "data-disconnect-machine"
    refute html =~ "Connect this machine"
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
      Path.join(System.tmp_dir!(), "sdd_machine_lifecycle_#{System.unique_integer([:positive])}")

    Path.join(dir, "store.dets")
  end

  defp git_root do
    Path.join(
      System.tmp_dir!(),
      "sdd_machine_lifecycle_repo_#{System.unique_integer([:positive])}"
    )
  end

  defp init_repo!(path) do
    File.mkdir_p!(path)
    git!(path, ["init", "-q"])
    git!(path, ["config", "user.email", "machine-lifecycle@example.test"])
    git!(path, ["config", "user.name", "Machine Lifecycle"])
    File.write!(Path.join(path, "README.md"), "unchanged #{Path.basename(path)}")
    git!(path, ["add", "README.md"])
    git!(path, ["commit", "-q", "-m", "initial"])
    path
  end

  defp git_snapshot(path) do
    %{
      head: git!(path, ["rev-parse", "HEAD"]),
      branches: git!(path, ["branch", "--format=%(refname)"]),
      remotes: git!(path, ["remote", "-v"]),
      status: git!(path, ["status", "--porcelain=v1"]),
      config: git!(path, ["config", "--local", "--list"])
    }
  end

  defp git!(path, args) do
    {output, 0} = System.cmd("git", ["-C", path | args], stderr_to_stdout: true)
    String.trim(output)
  end
end
