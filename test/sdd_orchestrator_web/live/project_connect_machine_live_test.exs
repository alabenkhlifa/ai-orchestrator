defmodule SddOrchestratorWeb.ProjectConnectMachineLiveTest do
  @moduledoc """
  Task 4 proof for connecting a machine from the hosted project page.

  A hosted project created normally — no backup package, no restore — must reach
  a connected state from its own page, and every refusal must leave it exactly as
  it was while naming what the owner can do next.
  """
  use SddOrchestratorWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias SddOrchestrator.Devices

  alias SddOrchestrator.Devices.{
    DeviceStore.Local,
    Pairing,
    PairingGuidance,
    PortableRepositoryIdentity
  }

  alias SddOrchestrator.Portability.{
    HostedLocalRepositoryBinding,
    PackageProvenance
  }

  alias SddOrchestrator.Projects.Project
  alias SddOrchestrator.ProjectsFixtures
  alias SddOrchestrator.Repo

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

    html = view |> element("[data-connect-machine]") |> render_click()

    assert html =~ ~s(data-worker-connection="connected")
    refute html =~ "data-connect-error"

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

    html = view |> element("[data-machine-option='#{first.id}']") |> render_click()

    assert html =~ ~s(data-worker-connection="connected")
    assert Repo.get!(HostedLocalRepositoryBinding, context.project.id).worker_id == first.id
  end

  test "a repository mismatch keeps the project unconnected with actionable copy",
       context do
    _worker = available_worker_fixture(context.device_workspace)
    other = init_repo!(Path.join(context.root, "different-repository"))
    point_picker_at(other)

    {:ok, view, _html} = live(context.conn, ~p"/projects/#{context.project.id}/overview")
    html = view |> element("[data-connect-machine]") |> render_click()

    assert html =~ ~s(data-worker-connection="disconnected")
    assert html =~ "data-connect-error"
    assert html =~ "isn&#39;t this project&#39;s repository"
    assert Repo.get(HostedLocalRepositoryBinding, context.project.id) == nil
  end

  test "a legacy repository identity is refused with its own upgrade guidance", context do
    _worker = available_worker_fixture(context.device_workspace)
    legacy_id = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    legacy = local_project_fixture(context.workspace, legacy_id, "Legacy Roadmap")

    {:ok, view, _html} = live(context.conn, ~p"/projects/#{legacy.id}/overview")
    html = view |> element("[data-connect-machine]") |> render_click()

    assert html =~ "data-connect-error"
    assert html =~ "tied to its original device workspace"
    assert Repo.get(HostedLocalRepositoryBinding, legacy.id) == nil
  end

  test "an unreachable machine is refused and told how to become reachable", context do
    _unreachable = paired_worker_fixture(context.device_workspace)

    {:ok, view, _html} = live(context.conn, ~p"/projects/#{context.project.id}/overview")
    html = view |> element("[data-connect-machine]") |> render_click()

    assert html =~ ~s(data-worker-connection="disconnected")
    assert html =~ "isn&#39;t reachable right now"
    assert html =~ "Open the worker app"
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

  test "a cancelled folder selection changes nothing and says nothing", context do
    _worker = available_worker_fixture(context.device_workspace)
    Application.put_env(:sdd_orchestrator, :device_worker_stub, false)
    on_exit(fn -> Application.put_env(:sdd_orchestrator, :device_worker_stub, true) end)

    {:ok, view, _html} = live(context.conn, ~p"/projects/#{context.project.id}/overview")
    html = view |> element("[data-connect-machine]") |> render_click()

    assert html =~ ~s(data-worker-connection="disconnected")
    assert html =~ "folder picker"
    assert Repo.get(HostedLocalRepositoryBinding, context.project.id) == nil
  end

  test "a repeated submit resolves to the same binding, not a second one", context do
    worker = available_worker_fixture(context.device_workspace)

    {:ok, view, _html} = live(context.conn, ~p"/projects/#{context.project.id}/overview")
    html = view |> element("[data-connect-machine]") |> render_click()
    assert html =~ ~s(data-worker-connection="connected")

    first = Repo.get!(HostedLocalRepositoryBinding, context.project.id)

    {:ok, second_view, _html} = live(context.conn, ~p"/projects/#{context.project.id}/overview")
    render_click(second_view, "connect_machine", %{})

    assert Repo.aggregate(HostedLocalRepositoryBinding, :count) == 1
    again = Repo.get!(HostedLocalRepositoryBinding, context.project.id)
    assert again.project_id == first.project_id
    assert again.worker_id == worker.id
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
