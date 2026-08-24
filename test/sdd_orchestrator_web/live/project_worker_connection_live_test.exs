defmodule SddOrchestratorWeb.ProjectWorkerConnectionLiveTest do
  @moduledoc """
  Task 3 proof for the hosted project page's worker connection state.

  The page must be correct for a project that was never connected and for one
  connected by any means, must present unreachability without implying the
  project is lost, must disclose no repository path, credential, worker id,
  device label, or compatibility descriptor, and must show nothing at all for a
  GitHub-backed project.
  """
  use SddOrchestratorWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias SddOrchestrator.Accounts.DeviceWorkspace
  alias SddOrchestrator.Devices.{Pairing, PortableRepositoryIdentity, WorkerDiscovery}
  alias SddOrchestrator.Portability.{HostedLocalRepositoryBinding, HostedLocalRepositoryBindings}
  alias SddOrchestrator.Projects.Project
  alias SddOrchestrator.ProjectsFixtures
  alias SddOrchestrator.Repo

  setup %{conn: conn} do
    %{conn: conn, account: account} = register_and_log_in_account(%{conn: conn, login: "octo"})
    workspace = ProjectsFixtures.workspace_fixture(account)

    root = git_root()
    on_exit(fn -> File.rm_rf!(root) end)

    repository = init_repo!(Path.join(root, "connected-repository"))
    {:ok, repository_id} = PortableRepositoryIdentity.generate(repository)
    project = local_project_fixture(workspace, repository_id, "Local Roadmap")

    %{
      conn: conn,
      workspace: workspace,
      project: project,
      repository: repository,
      repository_id: repository_id
    }
  end

  test "a never-connected project reads as not connected, not as a lost project",
       context do
    {:ok, _view, html} = live(context.conn, ~p"/projects/#{context.project.id}/overview")

    assert html =~ ~s(data-worker-connection="disconnected")
    assert html =~ "No machine connected yet"
    assert html =~ "Your project and its specifications are already saved."
  end

  test "a connected project shows its connection state", context do
    connect_worker(context)

    {:ok, _view, html} = live(context.conn, ~p"/projects/#{context.project.id}/overview")

    assert html =~ ~s(data-worker-connection="connected")
    assert html =~ "Connected to your machine"
  end

  test "a connected project with a stale heartbeat reads as temporarily unavailable",
       context do
    %{worker: worker} = connect_worker(context)

    stale =
      DateTime.utc_now()
      |> DateTime.add(-(WorkerDiscovery.staleness_seconds() + 60), :second)
      |> DateTime.truncate(:second)

    worker |> Ecto.Changeset.change(last_seen_at: stale) |> Repo.update!()

    {:ok, _view, html} = live(context.conn, ~p"/projects/#{context.project.id}/overview")

    assert html =~ ~s(data-worker-connection="temporarily_unavailable")
    assert html =~ "isn&#39;t reachable right now"
    assert html =~ "are unaffected"
  end

  test "no state discloses a path, credential, worker id, or device descriptor",
       context do
    %{worker: worker, device_workspace: device_workspace} = connect_worker(context)
    binding = Repo.get!(HostedLocalRepositoryBinding, context.project.id)

    {:ok, _view, html} = live(context.conn, ~p"/projects/#{context.project.id}/overview")

    assert html =~ ~s(data-worker-connection="connected")
    refute html =~ context.repository
    refute html =~ context.repository_id
    refute html =~ worker.id
    refute html =~ device_workspace.id
    refute html =~ worker.credential_digest
    refute html =~ worker.app_version
    refute html =~ to_string(binding.last_validated_at)

    assert {:ok, :disconnected} =
             HostedLocalRepositoryBindings.disconnect(context.workspace, context.project.id)

    {:ok, _view, html} = live(context.conn, ~p"/projects/#{context.project.id}/overview")

    assert html =~ ~s(data-worker-connection="disconnected")
    refute html =~ context.repository
    refute html =~ worker.id
  end

  test "a GitHub-backed project shows no worker connection region", context do
    github_project = ProjectsFixtures.registered_project(context.workspace, name: "Roadmap")

    {:ok, _view, html} = live(context.conn, ~p"/projects/#{github_project.id}/overview")

    assert html =~ ~s(data-screen="project-dashboard")
    refute html =~ "data-worker-connection"
    refute html =~ "No machine connected yet"
    refute html =~ "Connected to your machine"
  end

  defp connect_worker(context) do
    device_workspace = %DeviceWorkspace{id: Ecto.UUID.generate()}
    worker = available_worker_fixture(device_workspace)

    {:ok, %{binding: _binding}} =
      HostedLocalRepositoryBindings.put_validated_binding(
        context.workspace,
        context.project.id,
        device_workspace,
        worker.id,
        context.repository_id
      )

    %{device_workspace: device_workspace, worker: worker}
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

  defp git_root do
    Path.join(
      System.tmp_dir!(),
      "sdd_project_worker_connection_#{System.unique_integer([:positive])}"
    )
  end

  defp init_repo!(path) do
    File.mkdir_p!(path)
    git!(path, ["init", "-q"])
    git!(path, ["config", "user.email", "worker-connection@example.test"])
    git!(path, ["config", "user.name", "Worker Connection"])
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
