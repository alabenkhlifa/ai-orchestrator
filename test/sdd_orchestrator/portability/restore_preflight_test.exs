defmodule SddOrchestrator.Portability.RestorePreflightTest do
  @moduledoc """
  Task 5 proof for visibility-bounded stable-identity preflight.
  """

  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.AccountsFixtures
  alias SddOrchestrator.Catalog
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.{DeviceStore.Local, Pairing}

  alias SddOrchestrator.Portability.{
    PackageSection,
    ProjectPackage,
    RestorePreflight
  }

  alias SddOrchestrator.Projects.Project
  alias SddOrchestrator.ProjectsFixtures

  setup do
    path = store_path()
    on_exit(fn -> File.rm_rf!(Path.dirname(path)) end)
    start_supervised!({Local, path: path})

    account = AccountsFixtures.account_fixture()
    hosted_authority = ProjectsFixtures.workspace_fixture(account)
    {:ok, device_authority} = Devices.establish_workspace()

    %{
      account: account,
      hosted_authority: hosted_authority,
      device_authority: device_authority
    }
  end

  test "rejects an identity already in the selected hosted destination without mutation", %{
    hosted_authority: hosted_authority
  } do
    project = ProjectsFixtures.project_fixture(hosted_authority, %{name: "Existing hosted"})
    package = package(project.id)

    assert {:error, {:same_identity, %{project_id: project_id, boundaries: [:hosted]}}} =
             RestorePreflight.check_identity(package, hosted_authority)

    assert project_id == project.id
    assert Repo.aggregate(Project, :count) == 1
    assert Repo.get!(Project, project.id).name == "Existing hosted"
  end

  test "rejects an identity already in the selected device destination without mutation", %{
    device_authority: device_authority
  } do
    pair_available_worker(device_authority.id)

    {:ok, project} =
      Devices.register_project(%{
        name: "Existing device",
        repository_fingerprint: portable_identity(),
        status: "connected"
      })

    assert {:error, {:same_identity, %{project_id: project_id, boundaries: [:device]}}} =
             RestorePreflight.check_identity(package(project.id), device_authority)

    assert project_id == project.id
    assert {:ok, unchanged} = Devices.get_project(project.id)
    assert unchanged.name == "Existing device"
    assert length(Devices.list_projects()) == 1
    assert Repo.aggregate(Project, :count) == 0
  end

  test "checks a different currently accessible catalog", %{
    hosted_authority: hosted_authority,
    device_authority: device_authority
  } do
    pair_available_worker(device_authority.id)

    {:ok, project} =
      Devices.register_project(%{
        name: "Visible device",
        repository_fingerprint: portable_identity(),
        status: "connected"
      })

    assert {:error, {:same_identity, %{project_id: project_id, boundaries: [:device]}}} =
             RestorePreflight.check_identity(
               package(project.id),
               hosted_authority,
               [device_authority]
             )

    assert project_id == project.id
    assert Repo.aggregate(Project, :count) == 0
    assert length(Devices.list_projects()) == 1
  end

  test "does not inspect a signed-out hosted catalog", %{
    hosted_authority: hosted_authority,
    device_authority: device_authority
  } do
    pair_available_worker(device_authority.id)
    hosted_project = ProjectsFixtures.project_fixture(hosted_authority)

    assert {:ok, %{project_id: project_id, checked_boundaries: [:device]}} =
             RestorePreflight.check_identity(package(hosted_project.id), device_authority)

    assert project_id == hosted_project.id
    assert Repo.get!(Project, hosted_project.id).id == hosted_project.id
    assert Devices.list_projects() == []
  end

  test "does not query a device catalog whose worker is unavailable", %{
    hosted_authority: hosted_authority,
    device_authority: device_authority
  } do
    {:ok, device_project} =
      Devices.register_project(%{
        name: "Unavailable device",
        repository_fingerprint: portable_identity(),
        status: "connected"
      })

    assert Devices.worker_status(device_authority.id) == :missing

    assert {:ok, %{project_id: project_id, checked_boundaries: [:hosted]}} =
             RestorePreflight.check_identity(
               package(device_project.id),
               hosted_authority,
               [device_authority]
             )

    assert project_id == device_project.id
    assert {:ok, unchanged} = Devices.get_project(device_project.id)
    assert unchanged.id == device_project.id
  end

  test "fails when the selected device destination is no longer available", %{
    device_authority: device_authority
  } do
    assert {:error, :destination_unavailable} =
             RestorePreflight.check_identity(package(Ecto.UUID.generate()), device_authority)
  end

  test "hands a later-visible same-id collision to the non-mutating combined catalog" do
    id = Ecto.UUID.generate()

    entries =
      Catalog.mark_identity_conflicts([
        catalog_entry(id, "hosted"),
        catalog_entry(id, "device")
      ])

    assert length(entries) == 2
    assert Enum.all?(entries, & &1.identity_conflict?)
    assert entries |> Enum.map(& &1.storage_mode) |> Enum.sort() == ["device", "hosted"]
  end

  test "rejects a malformed packaged project identity", %{
    hosted_authority: hosted_authority
  } do
    assert {:error, :invalid_package} =
             RestorePreflight.check_identity(package("not-a-uuid"), hosted_authority)
  end

  defp package(project_id) do
    %ProjectPackage{
      project: %PackageSection{
        name: :project,
        version: 1,
        content: %{"id" => project_id, "name" => "Restored project"}
      },
      repository: %PackageSection{
        name: :repository,
        version: 1,
        content: %{"provider" => "local", "repository_id" => portable_identity()}
      },
      specifications: %PackageSection{
        name: :specifications,
        version: 1,
        content: []
      }
    }
  end

  defp pair_available_worker(workspace_id) do
    {:ok, %{code: code}} = Pairing.start_pairing(workspace_id)

    {:ok, %{worker: worker}} =
      Pairing.complete_pairing(code, %{
        os_family: "macos",
        os_major: "15",
        protocol_version: "1"
      })

    {:ok, _worker} = Pairing.mark_seen(worker)
  end

  defp portable_identity, do: ProjectsFixtures.local_repository_metadata().fingerprint

  defp catalog_entry(id, storage_mode) do
    %{
      id: id,
      name: "Visible collision",
      storage_mode: storage_mode,
      availability: if(storage_mode == "hosted", do: :connected, else: :available),
      repository_label: nil,
      route: "/projects/#{id}",
      identity_conflict?: false
    }
  end

  defp store_path do
    dir = Path.join(System.tmp_dir!(), "sdd_preflight_#{System.unique_integer([:positive])}")
    Path.join(dir, "store.dets")
  end
end
