defmodule SddOrchestrator.Portability.RestoreConflictsTest do
  @moduledoc """
  Task 11 proof for stable-identity, canonical-repository, and display-name
  conflict precedence and recovery.
  """

  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.AccountsFixtures
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.{DeviceStore.Local, Pairing}

  alias SddOrchestrator.Portability.{
    PackageSection,
    ProjectPackage,
    RestoreConflicts,
    RestoreDecision
  }

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

    %{
      hosted_authority: hosted_authority,
      device_authority: device_authority
    }
  end

  test "returns the packaged values when no selected-destination conflict exists", %{
    hosted_authority: authority
  } do
    project_id = Ecto.UUID.generate()

    assert {:ok,
            %RestoreDecision{
              project_id: ^project_id,
              display_name: "Restored project",
              repository_provider: "github",
              repository_id: "9001",
              checked_boundaries: [:hosted]
            }} =
             RestoreConflicts.evaluate(
               package(project_id, "  Restored project  ", "github", "9001"),
               authority
             )
  end

  test "stable identity takes precedence over repository and name conflicts", %{
    hosted_authority: authority
  } do
    project =
      ProjectsFixtures.registered_project(authority,
        name: "Taken",
        repository: ProjectsFixtures.repository_metadata(id: 501)
      )

    assert {:conflict, %{type: :same_identity, project_id: project_id, boundaries: [:hosted]}} =
             RestoreConflicts.evaluate(
               package(project.id, "taken", "github", "501"),
               authority
             )

    assert project_id == project.id
    assert Repo.aggregate(Project, :count) == 1
    assert Repo.aggregate(RepositoryConnection, :count) == 1
  end

  test "canonical repository conflict blocks with or without a name conflict", %{
    hosted_authority: authority
  } do
    _project =
      ProjectsFixtures.registered_project(authority,
        name: "Taken",
        repository: ProjectsFixtures.repository_metadata(id: 502)
      )

    assert {:conflict, %{type: :repository, provider: "github", repository_id: "502"}} =
             RestoreConflicts.evaluate(
               package(Ecto.UUID.generate(), "Available", "github", "502"),
               authority
             )

    assert {:conflict, %{type: :repository, provider: "github", repository_id: "502"}} =
             RestoreConflicts.evaluate(
               package(Ecto.UUID.generate(), "taken", "github", "502"),
               authority,
               replacement_name: "Different"
             )
  end

  test "name-only conflict requires an explicit replacement and never auto-renames", %{
    hosted_authority: authority
  } do
    _project = ProjectsFixtures.project_fixture(authority, %{name: "Roadmap"})
    package = package(Ecto.UUID.generate(), "roadmap", "github", "503")

    assert {:conflict,
            %{
              type: :name,
              packaged_name: "roadmap",
              requested_name: nil
            }} = RestoreConflicts.evaluate(package, authority)

    assert Repo.aggregate(Project, :count) == 1
  end

  test "accepts one explicit valid available replacement for a name-only conflict", %{
    hosted_authority: authority
  } do
    _project = ProjectsFixtures.project_fixture(authority, %{name: "Roadmap"})
    project_id = Ecto.UUID.generate()

    assert {:ok,
            %RestoreDecision{
              project_id: ^project_id,
              display_name: "Delivery plan",
              repository_provider: "github",
              repository_id: "504"
            }} =
             RestoreConflicts.evaluate(
               package(project_id, "ROADMAP", "github", "504"),
               authority,
               replacement_name: "  Delivery plan  "
             )

    assert Repo.aggregate(Project, :count) == 1
  end

  test "rejects invalid and repeatedly conflicting replacement names", %{
    hosted_authority: authority
  } do
    _first = ProjectsFixtures.project_fixture(authority, %{name: "Roadmap"})
    _second = ProjectsFixtures.project_fixture(authority, %{name: "Delivery plan"})
    package = package(Ecto.UUID.generate(), "roadmap", "github", "505")

    assert {:error, {:invalid_name, changeset}} =
             RestoreConflicts.evaluate(package, authority, replacement_name: " \n ")

    assert %{name: ["can't be blank"]} = errors_on(changeset)

    assert {:conflict,
            %{
              type: :name,
              packaged_name: "roadmap",
              requested_name: "delivery PLAN"
            }} =
             RestoreConflicts.evaluate(
               package,
               authority,
               replacement_name: "delivery PLAN"
             )
  end

  test "does not permit changing an available packaged name", %{hosted_authority: authority} do
    assert {:error, :replacement_not_allowed} =
             RestoreConflicts.evaluate(
               package(Ecto.UUID.generate(), "Available", "github", "506"),
               authority,
               replacement_name: "Unrequested rename"
             )
  end

  test "uses the device destination's case-insensitive name and local repository identity", %{
    device_authority: authority
  } do
    repository_id = ProjectsFixtures.local_repository_metadata().fingerprint

    {:ok, _project} =
      Devices.register_project(%{
        name: "Device roadmap",
        repository_fingerprint: repository_id,
        status: "connected"
      })

    assert {:conflict,
            %{
              type: :repository,
              provider: "local",
              repository_id: ^repository_id
            }} =
             RestoreConflicts.evaluate(
               package(Ecto.UUID.generate(), "device ROADMAP", "local", repository_id),
               authority
             )

    assert length(Devices.list_projects()) == 1
    assert Repo.aggregate(Project, :count) == 0
  end

  test "evaluation and cancellation by omission create no project or connection", %{
    hosted_authority: authority
  } do
    existing = ProjectsFixtures.project_fixture(authority, %{name: "Keep"})
    before = {Repo.aggregate(Project, :count), Repo.aggregate(RepositoryConnection, :count)}

    assert {:conflict, %{type: :name}} =
             RestoreConflicts.evaluate(
               package(Ecto.UUID.generate(), "keep", "github", "507"),
               authority
             )

    assert {Repo.aggregate(Project, :count), Repo.aggregate(RepositoryConnection, :count)} ==
             before

    assert Repo.get!(Project, existing.id).name == "Keep"
  end

  defp package(project_id, name, provider, repository_id) do
    %ProjectPackage{
      project: %PackageSection{
        name: :project,
        version: 1,
        content: %{"id" => project_id, "name" => name}
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

  defp store_path do
    dir = Path.join(System.tmp_dir!(), "sdd_conflicts_#{System.unique_integer([:positive])}")
    Path.join(dir, "store.dets")
  end
end
