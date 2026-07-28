defmodule SddOrchestrator.Specifications.SnapshotTest do
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Devices.DeviceStore.Local

  alias SddOrchestrator.{
    AccountsFixtures,
    Devices,
    ProjectsFixtures,
    SpecificationFixtures,
    SpecificationStore
  }

  setup do
    account = AccountsFixtures.account_fixture()
    workspace = ProjectsFixtures.workspace_fixture(account)
    project = ProjectsFixtures.registered_project(workspace)
    %{workspace: workspace, project: project}
  end

  test "returns a deterministically ordered hosted allowlist with current heads only", context do
    second =
      SpecificationFixtures.hosted_specification(
        context.workspace,
        context.project,
        id: "ffffffff-ffff-4fff-8fff-ffffffffffff",
        title: "Second"
      )

    first =
      SpecificationFixtures.hosted_specification(
        context.workspace,
        context.project,
        id: "00000000-0000-4000-8000-000000000001",
        title: "First"
      )

    assert {:ok, snapshot} =
             SpecificationStore.current_snapshot(context.workspace, context.project.id)

    assert Enum.map(snapshot.specifications, & &1.id) == [
             first.specification.id,
             second.specification.id
           ]

    assert Map.keys(Map.from_struct(hd(snapshot.specifications))) |> Enum.sort() ==
             [:design, :id, :requirements, :revision_id, :tasks, :title]

    refute inspect(snapshot) =~ "actor_ref"
    refute inspect(snapshot) =~ "content_digest"
    refute inspect(snapshot) =~ "storage_mode"
    refute inspect(snapshot) =~ "repository"
  end

  test "observes either complete revision around a concurrent append, never mixed documents",
       context do
    current = SpecificationFixtures.hosted_specification(context.workspace, context.project)

    marker = "revision-two"

    append = %{
      revision_id: Ecto.UUID.generate(),
      actor_ref: "owner",
      documents: %{
        requirements: marker,
        design: marker,
        tasks: marker
      }
    }

    task =
      Task.async(fn ->
        SpecificationStore.append_revision(
          context.workspace,
          context.project.id,
          current.specification.id,
          current.revision.id,
          append
        )
      end)

    assert {:ok, snapshot} =
             SpecificationStore.current_snapshot(context.workspace, context.project.id)

    assert {:ok, _appended} = Task.await(task)

    [entry] = snapshot.specifications

    assert {entry.requirements, entry.design, entry.tasks} in [
             {
               current.revision.requirements_document,
               current.revision.design_document,
               current.revision.tasks_document
             },
             {marker, marker, marker}
           ]
  end

  test "enforces the configured total snapshot byte limit", context do
    current = SpecificationFixtures.hosted_specification(context.workspace, context.project)
    previous_limits = Application.get_env(:sdd_orchestrator, :specification_limits)

    on_exit(fn ->
      Application.put_env(:sdd_orchestrator, :specification_limits, previous_limits)
    end)

    Application.put_env(
      :sdd_orchestrator,
      :specification_limits,
      Keyword.put(previous_limits, :max_snapshot_bytes, 1)
    )

    assert {:error, :snapshot_too_large} =
             SpecificationStore.current_snapshot(context.workspace, context.project.id)

    assert {:ok, _current} =
             SpecificationStore.get_current(
               context.workspace,
               context.project.id,
               current.specification.id
             )
  end

  test "returns the same allowlisted shape from the device authority without a hosted copy" do
    path = store_path()
    on_exit(fn -> File.rm_rf!(Path.dirname(path)) end)
    start_supervised!({Local, path: path})
    {:ok, device_workspace} = Devices.establish_workspace()

    {:ok, device_project} =
      Devices.register_project(%{
        name: "Device",
        repository_fingerprint: "snapshot-device",
        status: "connected"
      })

    attrs = SpecificationFixtures.specification_attrs()

    assert {:ok, _created} =
             SpecificationStore.create(device_workspace, device_project.id, attrs)

    assert {:ok, snapshot} =
             SpecificationStore.current_snapshot(device_workspace, device_project.id)

    assert [entry] = snapshot.specifications
    assert entry.id == attrs.id

    assert Map.keys(Map.from_struct(entry)) |> Enum.sort() ==
             [:design, :id, :requirements, :revision_id, :tasks, :title]

    assert SddOrchestrator.Repo.aggregate(
             SddOrchestrator.Specifications.ProjectSpecification,
             :count
           ) == 0
  end

  test "fails closed for a foreign hosted project", context do
    other_workspace = ProjectsFixtures.workspace_fixture(AccountsFixtures.account_fixture())

    assert {:error, :not_found} =
             SpecificationStore.current_snapshot(other_workspace, context.project.id)
  end

  defp store_path do
    Path.join(
      System.tmp_dir!(),
      "snapshot_device_store_#{System.unique_integer([:positive])}/store.dets"
    )
  end
end
