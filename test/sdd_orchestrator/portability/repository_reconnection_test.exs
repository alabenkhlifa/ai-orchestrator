defmodule SddOrchestrator.Portability.RepositoryReconnectionTest do
  @moduledoc """
  Task 13 proof for the unconnected restored-repository boundary.
  """

  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.AccountsFixtures
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.{DeviceStore.Local, Pairing}

  alias SddOrchestrator.Portability.{
    DeviceRestore,
    HostedRestore,
    PackageSection,
    ProjectPackage,
    RepositoryReconnection,
    RestoreDecision
  }

  alias SddOrchestrator.Portability.RepositoryReconnection.Request
  alias SddOrchestrator.Projects.{Project, RepositoryConnection}
  alias SddOrchestrator.ProjectsFixtures

  setup do
    path = store_path()
    on_exit(fn -> File.rm_rf!(Path.dirname(path)) end)
    start_supervised!({Local, path: path})

    account = AccountsFixtures.account_fixture()
    hosted_authority = ProjectsFixtures.workspace_fixture(account)
    {:ok, device_authority} = Devices.establish_workspace()
    pair_available_worker(device_authority.id)

    %{hosted_authority: hosted_authority, device_authority: device_authority}
  end

  test "hosted restoration creates no connection and returns only explicit GitHub authorization",
       %{hosted_authority: authority} do
    package = package("github", "9101")

    assert {:ok, %{project: project}} =
             HostedRestore.restore(authority, package, decision(package, :hosted),
               idempotency_key: "hosted-reconnection-boundary"
             )

    assert is_nil(project.repository_connection)
    assert Repo.aggregate(RepositoryConnection, :count) == 0

    before = Repo.get!(Project, project.id)

    assert {:ok,
            %Request{
              project_id: project_id,
              repository_provider: "github",
              repository_id: "9101",
              method: :github_authorization
            } = request} = RepositoryReconnection.required(authority, project.id)

    assert project_id == project.id

    assert request_fields(request) == [
             :method,
             :project_id,
             :repository_id,
             :repository_provider
           ]

    assert Repo.get!(Project, project.id) == before
    assert Repo.aggregate(RepositoryConnection, :count) == 0
  end

  test "a restored local identity uses the normal worker-validation handoff", %{
    hosted_authority: authority
  } do
    repository_id = portable_identity()
    package = package("local", repository_id)

    assert {:ok, %{project: project}} =
             HostedRestore.restore(authority, package, decision(package, :hosted),
               idempotency_key: "hosted-local-reconnection"
             )

    assert {:ok,
            %Request{
              repository_provider: "local",
              repository_id: ^repository_id,
              method: :local_worker_validation
            }} = RepositoryReconnection.required(authority, project.id)

    assert Repo.aggregate(RepositoryConnection, :count) == 0
  end

  test "device restoration remains disconnected and returns the provider-specific explicit action",
       %{device_authority: authority} do
    github_package = package("github", "9102")

    assert {:ok, %{project: github_project}} =
             DeviceRestore.restore(authority, github_package, decision(github_package, :device),
               idempotency_key: "device-github-reconnection"
             )

    assert github_project.status == "disconnected"

    assert {:ok,
            %Request{
              repository_provider: "github",
              repository_id: "9102",
              method: :github_authorization
            }} = RepositoryReconnection.required(authority, github_project.id)

    repository_id = portable_identity()
    local_package = package("local", repository_id)

    assert {:ok, %{project: local_project}} =
             DeviceRestore.restore(authority, local_package, decision(local_package, :device),
               idempotency_key: "device-local-reconnection"
             )

    assert local_project.status == "disconnected"

    assert {:ok,
            %Request{
              repository_provider: "local",
              repository_id: ^repository_id,
              method: :local_worker_validation
            }} = RepositoryReconnection.required(authority, local_project.id)

    assert Enum.all?(Devices.list_projects(), &(&1.status == "disconnected"))
    assert Repo.aggregate(Project, :count) == 0
    assert Repo.aggregate(RepositoryConnection, :count) == 0
  end

  test "normal connected projects and foreign boundaries expose no restore handoff", %{
    hosted_authority: hosted_authority,
    device_authority: device_authority
  } do
    hosted_project = ProjectsFixtures.registered_project(hosted_authority)

    assert {:error, :not_found} =
             RepositoryReconnection.required(hosted_authority, hosted_project.id)

    {:ok, device_project} =
      Devices.register_project(%{
        name: "Connected device",
        repository_fingerprint: "fp-connected-device",
        status: "connected"
      })

    assert {:error, :already_connected} =
             RepositoryReconnection.required(device_authority, device_project.id)

    foreign_hosted = %{hosted_authority | id: Ecto.UUID.generate()}
    foreign_device = %{device_authority | id: Ecto.UUID.generate()}

    assert {:error, :not_found} =
             RepositoryReconnection.required(foreign_hosted, hosted_project.id)

    assert {:error, :not_found} =
             RepositoryReconnection.required(foreign_device, device_project.id)
  end

  defp package(provider, repository_id) do
    %ProjectPackage{
      project: %PackageSection{
        name: :project,
        version: 1,
        content: %{
          "id" => Ecto.UUID.generate(),
          "name" => "Reconnection boundary #{repository_id}"
        }
      },
      repository: %PackageSection{
        name: :repository,
        version: 1,
        content: %{"provider" => provider, "repository_id" => repository_id}
      },
      specifications: %PackageSection{
        name: :specifications,
        version: 1,
        content: []
      }
    }
  end

  defp decision(package, boundary) do
    %RestoreDecision{
      project_id: package.project.content["id"],
      display_name: package.project.content["name"],
      repository_provider: package.repository.content["provider"],
      repository_id: package.repository.content["repository_id"],
      checked_boundaries: [boundary]
    }
  end

  defp request_fields(request) do
    request
    |> Map.from_struct()
    |> Map.keys()
    |> Enum.sort()
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

  defp portable_identity, do: ProjectsFixtures.local_repository_metadata().fingerprint

  defp store_path do
    dir =
      Path.join(System.tmp_dir!(), "sdd_reconnection_#{System.unique_integer([:positive])}")

    Path.join(dir, "store.dets")
  end
end
