defmodule SddOrchestrator.Portability.PackageProvenanceLifecycleTest do
  @moduledoc """
  Task 17 proof for minimal, project-authorized provenance and its hosted and
  device deletion lifecycle.
  """

  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Accounts.{DeviceWorkspace, PersonalWorkspace}
  alias SddOrchestrator.AccountsFixtures
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.{DeviceStore.Local, Pairing}

  alias SddOrchestrator.Portability.{
    DeviceRestore,
    PackageProvenance,
    PackageProvenances,
    PackageSection,
    ProjectPackage,
    RestoreDecision
  }

  alias SddOrchestrator.Privacy.{ProcessingInventory, Rights}
  alias SddOrchestrator.Projects.Project
  alias SddOrchestrator.ProjectsFixtures
  alias SddOrchestrator.Specifications.SpecificationLifecycle

  setup do
    path = store_path()
    on_exit(fn -> File.rm_rf!(Path.dirname(path)) end)
    start_supervised!({Local, path: path})
    {:ok, device_workspace} = Devices.establish_workspace()
    pair_available_worker(device_workspace.id)

    %{device_workspace: device_workspace, store_path: path}
  end

  test "keeps the persistent shape minimal and inventories its project-bound lifecycle" do
    assert PackageProvenance.__schema__(:fields) ==
             [:project_id, :payload_schema_version, :restored_at]

    record =
      Enum.find(ProcessingInventory.records(), &(&1.activity == :package_provenance))

    assert record.lawful_basis == :contract
    assert record.personal_data == ["project id", "payload schema version", "restoration time"]
    assert record.retention =~ "deleted with project erasure or service termination"
    assert Enum.any?(record.processors, &String.contains?(&1, "Hosting database"))
    assert Enum.any?(record.processors, &String.contains?(&1, "Device worker"))

    stored_fields =
      PackageProvenance.__schema__(:fields)
      |> Enum.map_join(" ", &Atom.to_string/1)

    refute String.match?(
             stored_fields,
             ~r/package_hash|filename|source|workspace|device|exporter|network|storage_mode/
           )
  end

  test "authorizes hosted and device provenance only through the current project", %{
    device_workspace: device_workspace
  } do
    {_account, hosted_workspace, hosted_project, hosted_provenance} = hosted_provenance()

    foreign_workspace =
      AccountsFixtures.account_fixture()
      |> ProjectsFixtures.workspace_fixture()

    assert {:ok, ^hosted_provenance} =
             PackageProvenances.get(hosted_workspace, hosted_project.id)

    assert {:error, :not_found} =
             PackageProvenances.get(foreign_workspace, hosted_project.id)

    %{project: device_project, provenance: device_provenance} =
      restore_device(device_workspace, "Authorized device provenance", "9201")

    assert {:ok, ^device_provenance} =
             PackageProvenances.get(device_workspace, device_project.id)

    assert {:error, :not_found} =
             PackageProvenances.get(
               %DeviceWorkspace{id: Ecto.UUID.generate()},
               device_project.id
             )

    assert {:error, :not_found} =
             PackageProvenances.get(
               %PersonalWorkspace{id: hosted_workspace.id},
               device_project.id
             )
  end

  test "hosted and device project deletion removes provenance and derived project data", %{
    device_workspace: device_workspace,
    store_path: path
  } do
    {_account, hosted_workspace, hosted_project, _hosted_provenance} = hosted_provenance()

    assert {:ok, %{project_id: hosted_id}} =
             SpecificationLifecycle.delete_project(hosted_workspace, hosted_project.id)

    assert hosted_id == hosted_project.id
    refute Repo.get(Project, hosted_project.id)
    refute Repo.get(PackageProvenance, hosted_project.id)

    %{project: device_project} =
      restore_device(device_workspace, "Deleted device provenance", "9202")

    assert {:ok,
            %{
              project_id: device_id,
              deleted_provenance: true,
              deleted_specifications: 0
            }} = SpecificationLifecycle.delete_project(device_workspace, device_project.id)

    assert device_id == device_project.id
    assert {:error, :not_found} = Devices.get_project(device_project.id)
    assert {:error, :not_found} = Devices.get_package_provenance(device_project.id)

    :ok = stop_supervised(Local)
    start_supervised!({Local, path: path})
    assert {:error, :not_found} = Devices.get_package_provenance(device_project.id)
  end

  test "account erasure and service termination remove hosted provenance idempotently" do
    {account, _workspace, project, _provenance} = hosted_provenance()
    {_other_account, _other_workspace, other_project, _other_provenance} = hosted_provenance()

    assert {:ok, %{account_id: account_id}} = Rights.erase_account(account.id)
    assert account_id == account.id
    refute Repo.get(PackageProvenance, project.id)
    assert Repo.get(PackageProvenance, other_project.id)

    assert {:ok, 1} = PackageProvenances.delete_all_for_service_termination()
    refute Repo.get(PackageProvenance, other_project.id)
    assert Repo.get(Project, other_project.id)
    assert {:ok, 0} = PackageProvenances.delete_all_for_service_termination()
  end

  defp hosted_provenance do
    account = AccountsFixtures.account_fixture()
    workspace = ProjectsFixtures.workspace_fixture(account)
    project = ProjectsFixtures.registered_project(workspace)

    provenance =
      %PackageProvenance{}
      |> PackageProvenance.create_changeset(%{
        project_id: project.id,
        payload_schema_version: 1,
        restored_at: ~U[2026-07-28 12:00:00Z]
      })
      |> Repo.insert!()

    {account, workspace, project, provenance}
  end

  defp restore_device(device_workspace, name, repository_id) do
    package =
      %ProjectPackage{
        project: %PackageSection{
          name: :project,
          version: 1,
          content: %{"id" => Ecto.UUID.generate(), "name" => name}
        },
        repository: %PackageSection{
          name: :repository,
          version: 1,
          content: %{"provider" => "github", "repository_id" => repository_id}
        },
        specifications: %PackageSection{
          name: :specifications,
          version: 1,
          content: []
        }
      }

    decision = %RestoreDecision{
      project_id: package.project.content["id"],
      display_name: name,
      repository_provider: "github",
      repository_id: repository_id,
      checked_boundaries: [:device]
    }

    assert {:ok, result} =
             DeviceRestore.restore(device_workspace, package, decision,
               idempotency_key: Ecto.UUID.generate()
             )

    result
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
    directory =
      Path.join(
        System.tmp_dir!(),
        "sdd_package_provenance_#{System.unique_integer([:positive])}"
      )

    Path.join(directory, "store.dets")
  end
end
