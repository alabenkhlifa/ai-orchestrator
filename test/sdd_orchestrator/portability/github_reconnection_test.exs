defmodule SddOrchestrator.Portability.GitHubReconnectionTest do
  @moduledoc """
  Task 20 proof for explicit GitHub reconnection through current provider
  authorization and exact canonical identity binding.
  """

  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Accounts
  alias SddOrchestrator.AccountsFixtures
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.{DeviceStore.Local, Pairing}

  alias SddOrchestrator.Portability.{
    DeviceRestore,
    GitHubReconnection,
    HostedRestore,
    PackageSection,
    ProjectPackage,
    RepositoryReconnection,
    RestoreDecision
  }

  alias SddOrchestrator.Projects.RepositoryConnection
  alias SddOrchestrator.ProjectsFixtures

  setup do
    path = store_path()
    on_exit(fn -> File.rm_rf!(Path.dirname(path)) end)
    start_supervised!({Local, path: path})

    account = AccountsFixtures.account_fixture(login: "reconnect-user")
    hosted_authority = ProjectsFixtures.workspace_fixture(account)
    {:ok, device_authority} = Devices.establish_workspace()
    pair_available_worker(device_authority.id)

    %{
      account: account,
      hosted_authority: hosted_authority,
      device_authority: device_authority
    }
  end

  test "connects an exact hosted GitHub repository through current metadata-read authorization",
       %{account: account, hosted_authority: authority} do
    package = package("101")
    project = restore_hosted(authority, package, "github-hosted-success")
    {:ok, request} = RepositoryReconnection.required(authority, project.id)

    assert {:ok,
            %{
              project_id: project_id,
              repository_provider: "github",
              repository_id: "101",
              status: :connected
            }} = GitHubReconnection.connect(account, authority, request)

    assert project_id == project.id
    connection = Repo.get_by!(RepositoryConnection, project_id: project.id)
    assert connection.provider == "github"
    assert connection.provider_repository_id == 101
    assert connection.full_name == "reconnect-user/example"
    assert connection.state == "connected"

    assert {:ok, %{status: :connected}} =
             GitHubReconnection.connect(account, authority, request)

    assert Repo.aggregate(RepositoryConnection, :count) == 1
  end

  test "connects an exact device project without creating a hosted connection", %{
    account: account,
    device_authority: authority
  } do
    package = package("202")
    project = restore_device(authority, package, "github-device-success")
    {:ok, request} = RepositoryReconnection.required(authority, project.id)

    assert {:ok, %{project_id: project_id, repository_id: "202", status: :connected}} =
             GitHubReconnection.connect(account, authority, request)

    assert project_id == project.id
    assert {:ok, connected} = Devices.get_project(project.id)
    assert connected.status == "connected"
    assert connected.repository_provider == "github"
    assert connected.repository_id == "202"
    assert Repo.aggregate(RepositoryConnection, :count) == 0
  end

  test "missing or failed current authorization leaves the restored project disconnected", %{
    account: account,
    hosted_authority: authority
  } do
    package = package("101")
    project = restore_hosted(authority, package, "github-missing-authorization")
    {:ok, request} = RepositoryReconnection.required(authority, project.id)

    credential = Accounts.get_github_credential(account.id)

    {:ok, _revoked} =
      credential
      |> Ecto.Changeset.change(revoked_at: DateTime.utc_now() |> DateTime.truncate(:second))
      |> Repo.update()

    assert {:error, :authorization_required} =
             GitHubReconnection.connect(account, authority, request)

    assert Repo.aggregate(RepositoryConnection, :count) == 0

    {failed_account, failed_authority, failed_request} =
      hosted_scenario("unauthorized-reconnect", "101", "github-failed-authorization")

    assert {:error, :authorization_required} =
             GitHubReconnection.connect(failed_account, failed_authority, failed_request)

    assert Repo.aggregate(RepositoryConnection, :count) == 0
  end

  test "provider failure and canonical mismatch are actionable and non-mutating" do
    {limited_account, limited_authority, limited_request} =
      hosted_scenario("ratelimit-reconnect", "101", "github-provider-unavailable")

    assert {:error, :provider_unavailable} =
             GitHubReconnection.connect(limited_account, limited_authority, limited_request)

    {account, authority, request} =
      hosted_scenario("mismatch-reconnect", "999999", "github-canonical-mismatch")

    assert {:error, :canonical_repository_mismatch} =
             GitHubReconnection.connect(account, authority, request)

    assert Repo.aggregate(RepositoryConnection, :count) == 0
  end

  test "rejects a forged, local, or cross-workspace request", %{
    account: account,
    hosted_authority: authority
  } do
    package = package("101")
    project = restore_hosted(authority, package, "github-request-binding")
    {:ok, request} = RepositoryReconnection.required(authority, project.id)

    assert {:error, :invalid_request} =
             GitHubReconnection.connect(account, authority, %{request | repository_id: "202"})

    assert {:error, :invalid_request} =
             GitHubReconnection.connect(account, authority, %{
               request
               | method: :local_worker_validation
             })

    foreign_account = AccountsFixtures.account_fixture()

    assert {:error, :not_found} =
             GitHubReconnection.connect(foreign_account, authority, request)

    assert Repo.aggregate(RepositoryConnection, :count) == 0
  end

  test "reconnection leaves repository content, branches, remotes, settings, and Git config unchanged",
       %{account: account, hosted_authority: authority} do
    fixture = git_fixture()
    before = git_snapshot(fixture)
    package = package("301")
    project = restore_hosted(authority, package, "github-repository-nonmutation")
    {:ok, request} = RepositoryReconnection.required(authority, project.id)

    assert {:ok, %{status: :connected}} =
             GitHubReconnection.connect(account, authority, request)

    assert git_snapshot(fixture) == before
  end

  defp hosted_scenario(login, repository_id, idempotency_key) do
    account = AccountsFixtures.account_fixture(login: login)
    authority = ProjectsFixtures.workspace_fixture(account)
    project = restore_hosted(authority, package(repository_id), idempotency_key)
    {:ok, request} = RepositoryReconnection.required(authority, project.id)
    {account, authority, request}
  end

  defp restore_hosted(authority, package, idempotency_key) do
    {:ok, %{project: project}} =
      HostedRestore.restore(authority, package, decision(package, :hosted),
        idempotency_key: idempotency_key
      )

    project
  end

  defp restore_device(authority, package, idempotency_key) do
    {:ok, %{project: project}} =
      DeviceRestore.restore(authority, package, decision(package, :device),
        idempotency_key: idempotency_key
      )

    project
  end

  defp package(repository_id) do
    %ProjectPackage{
      project: %PackageSection{
        name: :project,
        version: 1,
        content: %{
          "id" => Ecto.UUID.generate(),
          "name" => "GitHub reconnect #{repository_id}-#{System.unique_integer([:positive])}"
        }
      },
      repository: %PackageSection{
        name: :repository,
        version: 1,
        content: %{"provider" => "github", "repository_id" => repository_id}
      },
      specifications: %PackageSection{name: :specifications, version: 1, content: []}
    }
  end

  defp decision(package, boundary) do
    %RestoreDecision{
      project_id: package.project.content["id"],
      display_name: package.project.content["name"],
      repository_provider: "github",
      repository_id: package.repository.content["repository_id"],
      checked_boundaries: [boundary]
    }
  end

  defp pair_available_worker(workspace_id) do
    {:ok, %{code: code}} = Pairing.start_pairing(workspace_id)

    {:ok, %{worker: worker}} =
      Pairing.complete_pairing(code, %{
        os_family: "macos",
        os_major: "26",
        protocol_version: "1"
      })

    {:ok, _worker} = Pairing.mark_seen(worker)
  end

  defp git_fixture do
    root =
      Path.join(System.tmp_dir!(), "sdd_github_reconnect_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(root) end)
    File.mkdir_p!(root)
    git!(root, ["init", "-q"])
    git!(root, ["config", "user.email", "reconnect@example.test"])
    git!(root, ["config", "user.name", "Reconnect Test"])
    File.write!(Path.join(root, "README.md"), "unchanged")
    git!(root, ["add", "README.md"])
    git!(root, ["commit", "-q", "-m", "initial"])
    git!(root, ["remote", "add", "origin", "https://example.test/original.git"])
    root
  end

  defp git_snapshot(root) do
    %{
      head: git!(root, ["rev-parse", "HEAD"]),
      status: git!(root, ["status", "--porcelain=v1"]),
      branches: git!(root, ["branch", "--format=%(refname)"]),
      remotes: git!(root, ["remote", "-v"]),
      config: git!(root, ["config", "--local", "--list"])
    }
  end

  defp git!(root, args) do
    {output, 0} = System.cmd("git", ["-C", root | args], stderr_to_stdout: true)
    output
  end

  defp store_path do
    dir = Path.join(System.tmp_dir!(), "sdd_github_#{System.unique_integer([:positive])}")
    Path.join(dir, "store.dets")
  end
end
