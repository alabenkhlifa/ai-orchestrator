defmodule SddOrchestrator.ProjectStorage.DomainBoundaryTest do
  @moduledoc """
  Task 2 proof for the common workspace root, destination-specific profiles,
  authoritative storage mode, hosted constraints, device-local ownership
  contract, workspace isolation, and rollback.
  """
  use SddOrchestrator.DataCase, async: true

  alias Ecto.Multi
  alias SddOrchestrator.Accounts

  alias SddOrchestrator.Accounts.{
    DeviceWorkspace,
    PersonalWorkspace,
    Workspace
  }

  alias SddOrchestrator.Projects.{Project, RepositoryConnection}

  alias SddOrchestrator.ProjectStorage.{
    ProjectStorageState,
    StorageMode
  }

  alias SddOrchestrator.AccountsFixtures
  alias SddOrchestrator.ProjectsFixtures

  test "a personal profile and hosted root share the stable existing workspace id" do
    account = AccountsFixtures.account_fixture()
    personal = ProjectsFixtures.workspace_fixture(account)

    assert personal.id == personal.workspace.id
    assert personal.workspace.kind == "hosted"
    assert Accounts.get_workspace(personal.id).id == personal.id
    assert Accounts.get_or_create_personal_workspace(account).id == personal.id
  end

  test "the hosted database rejects device roots" do
    {:ok, device_root} = Workspace.device_root()

    assert {:error, changeset} =
             device_root
             |> Workspace.changeset(%{})
             |> Repo.insert()

    assert %{kind: [_ | _]} = errors_on(changeset)
    assert Repo.aggregate(Workspace, :count) == 0
  end

  test "hosted persistence rejects a project whose mode does not match its root" do
    personal = ProjectsFixtures.workspace_fixture(AccountsFixtures.account_fixture())

    assert {:error, changeset} =
             %Project{}
             |> Project.registration_changeset(%{
               name: "Wrong destination",
               workspace_id: personal.id,
               storage_mode: "device"
             })
             |> Repo.insert()

    assert %{workspace_id: [_ | _]} = errors_on(changeset)
    assert Repo.aggregate(Project, :count) == 0
  end

  test "a hosted project derives one authoritative state from its root and detail row" do
    personal = ProjectsFixtures.workspace_fixture(AccountsFixtures.account_fixture())
    project = ProjectsFixtures.registered_project(personal)
    root = Accounts.get_workspace(personal.id)

    assert {:ok, state} =
             ProjectStorageState.from_project(project, root, project.hosted_storage)

    assert state.workspace_id == personal.id
    assert state.workspace_kind == "hosted"
    assert state.storage_mode == "hosted"

    assert {:error, :hosted_storage_required} =
             ProjectStorageState.from_project(project, root, :device_authoritative)
  end

  test "a repository connection cannot claim a different workspace than its project" do
    one = ProjectsFixtures.workspace_fixture(AccountsFixtures.account_fixture())
    two = ProjectsFixtures.workspace_fixture(AccountsFixtures.account_fixture())
    project = ProjectsFixtures.project_fixture(one)

    assert {:error, changeset} =
             %RepositoryConnection{}
             |> RepositoryConnection.create_changeset(%{
               project_id: project.id,
               workspace_id: two.id,
               provider: "github",
               provider_repository_id: 999,
               state: "connected"
             })
             |> Repo.insert()

    assert %{workspace_id: [_ | _]} = errors_on(changeset)
    assert Repo.aggregate(RepositoryConnection, :count) == 0
  end

  test "a device project remains owned by its device profile regardless of sign-in" do
    {:ok, root} = Workspace.device_root()
    {:ok, device_workspace} = DeviceWorkspace.from_workspace(root)

    project = %{
      id: Ecto.UUID.generate(),
      workspace_id: root.id,
      storage_mode: "device"
    }

    assert DeviceWorkspace.owns_project?(device_workspace, project)

    # A hosted identity may exist in the same session, but it is not part of the
    # device ownership record and cannot acquire the project.
    personal = ProjectsFixtures.workspace_fixture(AccountsFixtures.account_fixture())
    refute personal.id == project.workspace_id

    assert DeviceWorkspace.owns_project?(device_workspace, project)

    assert {:ok, state} =
             ProjectStorageState.from_project(project, root, :device_authoritative)

    assert state.workspace_kind == "device"
    assert state.storage_mode == "device"
    refute Map.has_key?(Map.from_struct(device_workspace), :account_id)
  end

  test "storage mode validation rejects cross-destination and invalid values" do
    assert StorageMode.compatible?("hosted", "hosted")
    assert StorageMode.compatible?(:device, "device")
    refute StorageMode.compatible?("device", "hosted")
    refute StorageMode.compatible?("cloud", "hosted")
  end

  test "a failed profile insert rolls back the new common root" do
    workspace_id = Ecto.UUID.generate()

    assert {:error, :personal_workspace, _changeset, _changes} =
             Multi.new()
             |> Multi.insert(
               :workspace,
               Workspace.changeset(%Workspace{id: workspace_id}, %{kind: "hosted"})
             )
             |> Multi.insert(
               :personal_workspace,
               PersonalWorkspace.changeset(%PersonalWorkspace{}, %{
                 id: workspace_id,
                 account_id: Ecto.UUID.generate()
               })
             )
             |> Repo.transaction()

    refute Repo.get(Workspace, workspace_id)
    refute Repo.get(PersonalWorkspace, workspace_id)
  end
end
