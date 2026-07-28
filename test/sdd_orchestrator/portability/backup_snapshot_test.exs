defmodule SddOrchestrator.Portability.BackupSnapshotTest do
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Accounts.DeviceWorkspace
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.DeviceStore.Local
  alias SddOrchestrator.Portability.{BackupSnapshot, PackageCodec}
  alias SddOrchestrator.SpecificationStore

  alias SddOrchestrator.Specifications.{
    ProjectSpecification,
    SpecificationRevision
  }

  alias SddOrchestrator.{AccountsFixtures, ProjectsFixtures, SpecificationFixtures}

  setup do
    account = AccountsFixtures.account_fixture()
    workspace = ProjectsFixtures.workspace_fixture(account)
    project = ProjectsFixtures.registered_project(workspace)
    path = store_path()
    on_exit(fn -> File.rm_rf!(Path.dirname(path)) end)
    start_supervised!({Local, path: path})
    {:ok, device_workspace} = Devices.establish_workspace()

    %{
      device_workspace: device_workspace,
      project: project,
      workspace: workspace
    }
  end

  test "maps the exact hosted project, repository, and current specification allowlist",
       context do
    attrs = SpecificationFixtures.specification_attrs(title: "Refund approval")

    assert {:ok, _current} =
             SpecificationStore.create(context.workspace, context.project.id, attrs)

    assert {:ok, package} = BackupSnapshot.build(context.workspace, context.project.id)
    assert Map.keys(package.project.content) |> Enum.sort() == ["id", "name"]
    assert package.project.content["id"] == context.project.id
    assert package.project.content["name"] == context.project.name

    assert package.repository.content == %{
             "provider" => "github",
             "repository_id" =>
               Integer.to_string(context.project.repository_connection.provider_repository_id)
           }

    assert package.specifications.content == [
             %{
               "id" => attrs.id,
               "title" => "Refund approval",
               "requirements" => attrs.documents.requirements,
               "design" => attrs.documents.design,
               "tasks" => attrs.documents.tasks
             }
           ]

    assert {:ok, payload} = PackageCodec.encode_payload(package)
    assert {:ok, decoded} = Jason.decode(payload)

    assert Enum.map(decoded["sections"], & &1["name"]) == [
             "project",
             "repository",
             "specifications"
           ]
  end

  test "fails closed for foreign hosted and device authorities", context do
    foreign_workspace =
      AccountsFixtures.account_fixture()
      |> ProjectsFixtures.workspace_fixture()

    assert {:error, :not_found} =
             BackupSnapshot.build(foreign_workspace, context.project.id)

    assert {:error, :not_found} =
             BackupSnapshot.build(
               %DeviceWorkspace{id: Ecto.UUID.generate()},
               Ecto.UUID.generate()
             )
  end

  test "observes one complete current document set during a concurrent append", context do
    attrs = SpecificationFixtures.specification_attrs()

    assert {:ok, current} =
             SpecificationStore.create(context.workspace, context.project.id, attrs)

    marker = "backup-snapshot-revision"

    append =
      Task.async(fn ->
        SpecificationStore.append_revision(
          context.workspace,
          context.project.id,
          current.specification.id,
          current.revision.id,
          %{
            revision_id: Ecto.UUID.generate(),
            documents: %{
              requirements: marker,
              design: marker,
              tasks: marker
            }
          }
        )
      end)

    assert {:ok, package} = BackupSnapshot.build(context.workspace, context.project.id)
    assert {:ok, _appended} = Task.await(append)
    [specification] = package.specifications.content

    assert {
             specification["requirements"],
             specification["design"],
             specification["tasks"]
           } in [
             {
               attrs.documents.requirements,
               attrs.documents.design,
               attrs.documents.tasks
             },
             {marker, marker, marker}
           ]
  end

  test "maps a device project without creating a hosted authoritative copy", context do
    portable_identity = portable_identity()

    {:ok, project} =
      Devices.register_project(%{
        name: "Device backup",
        repository_fingerprint: portable_identity,
        status: "connected",
        idempotency_key: Ecto.UUID.generate()
      })

    attrs = SpecificationFixtures.specification_attrs()

    assert {:ok, _current} =
             SpecificationStore.create(context.device_workspace, project.id, attrs)

    assert {:ok, package} = BackupSnapshot.build(context.device_workspace, project.id)

    assert package.repository.content == %{
             "provider" => "local",
             "repository_id" => portable_identity
           }

    assert Repo.aggregate(ProjectSpecification, :count) == 0
    assert Repo.aggregate(SpecificationRevision, :count) == 0
  end

  test "blocks legacy and malformed local identities before package creation", context do
    legacy_identity = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    for {name, identity, expected_error} <- [
          {"Legacy backup", legacy_identity, :repository_identity_upgrade_required},
          {"Malformed backup", "not-a-canonical-identity", :invalid_repository_identity}
        ] do
      {:ok, project} =
        Devices.register_project(%{
          name: name,
          repository_fingerprint: identity,
          status: "connected",
          idempotency_key: Ecto.UUID.generate()
        })

      before = Devices.get_project(project.id)

      assert {:error, ^expected_error} =
               BackupSnapshot.build(context.device_workspace, project.id)

      assert Devices.get_project(project.id) == before
    end

    assert Repo.aggregate(ProjectSpecification, :count) == 0
    assert Repo.aggregate(SpecificationRevision, :count) == 0
  end

  defp portable_identity do
    SddOrchestrator.ProjectsFixtures.local_repository_metadata().fingerprint
  end

  defp store_path do
    Path.join(
      System.tmp_dir!(),
      "backup_snapshot_store_#{System.unique_integer([:positive])}/store.dets"
    )
  end
end
