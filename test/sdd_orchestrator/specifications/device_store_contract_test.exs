defmodule SddOrchestrator.Specifications.DeviceStoreContractTest do
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Accounts.DeviceWorkspace
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.DeviceStore.Local
  alias SddOrchestrator.SpecificationStore

  alias SddOrchestrator.Specifications.{
    ProjectSpecification,
    SpecificationRevision
  }

  alias SddOrchestrator.SpecificationFixtures

  setup do
    path = store_path()
    on_exit(fn -> File.rm_rf!(Path.dirname(path)) end)
    start_supervised!({Local, path: path})

    {:ok, workspace} = Devices.establish_workspace()

    {:ok, project} =
      Devices.register_project(%{
        name: "Device project",
        repository_fingerprint: "device-project-fingerprint",
        status: "connected",
        idempotency_key: Ecto.UUID.generate()
      })

    %{path: path, workspace: workspace, project: project}
  end

  test "matches hosted create, append, and current-read behavior without a hosted copy",
       context do
    attrs = SpecificationFixtures.specification_attrs()

    assert {:ok, created} =
             SpecificationStore.create(
               context.workspace,
               context.project.id,
               attrs,
               actor_ref: "device-owner"
             )

    assert created.specification.id == attrs.id
    assert created.specification.project_id == context.project.id
    assert created.revision.sequence == 1
    assert created.revision.actor_ref == "device-owner"

    append = %{
      revision_id: Ecto.UUID.generate(),
      actor_ref: "device-owner",
      title: "Updated device specification",
      documents: SpecificationFixtures.documents(%{design: "device revision two"})
    }

    assert {:ok, updated} =
             SpecificationStore.append_revision(
               context.workspace,
               context.project.id,
               created.specification.id,
               created.revision.id,
               append
             )

    assert updated.revision.sequence == 2
    assert updated.specification.title == "Updated device specification"

    assert {:ok, current} =
             SpecificationStore.get_current(
               context.workspace,
               context.project.id,
               created.specification.id
             )

    assert current == updated
    assert Repo.aggregate(ProjectSpecification, :count) == 0
    assert Repo.aggregate(SpecificationRevision, :count) == 0
  end

  test "persists the authoritative aggregate across a worker restart", context do
    attrs = SpecificationFixtures.specification_attrs()

    assert {:ok, created} =
             SpecificationStore.create(context.workspace, context.project.id, attrs)

    stop_supervised!(Local)
    start_supervised!({Local, path: context.path})

    assert {:ok, reloaded_workspace} = Devices.get_workspace()
    assert reloaded_workspace.id == context.workspace.id

    assert {:ok, current} =
             SpecificationStore.get_current(
               reloaded_workspace,
               context.project.id,
               created.specification.id
             )

    assert current == created
  end

  test "fails closed for another device boundary and project", context do
    attrs = SpecificationFixtures.specification_attrs()
    other_workspace = %DeviceWorkspace{id: Ecto.UUID.generate()}

    assert {:error, :not_found} =
             SpecificationStore.create(other_workspace, context.project.id, attrs)

    assert {:error, :not_found} =
             SpecificationStore.create(context.workspace, Ecto.UUID.generate(), attrs)

    assert Devices.specification_count(context.project.id) == 0
  end

  test "serializes concurrent appends and makes a committed retry idempotent", context do
    attrs = SpecificationFixtures.specification_attrs()

    assert {:ok, created} =
             SpecificationStore.create(context.workspace, context.project.id, attrs)

    requests = [
      append_attrs("writer one"),
      append_attrs("writer two")
    ]

    results =
      requests
      |> Task.async_stream(
        fn append ->
          SpecificationStore.append_revision(
            context.workspace,
            context.project.id,
            created.specification.id,
            created.revision.id,
            append
          )
        end,
        max_concurrency: 2,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _current}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :stale_revision})) == 1

    {:ok, winner} = Enum.find(results, &match?({:ok, _current}, &1))

    winning_attrs =
      Enum.find(requests, fn request -> request.revision_id == winner.revision.id end)

    assert {:ok, retried} =
             SpecificationStore.append_revision(
               context.workspace,
               context.project.id,
               created.specification.id,
               created.revision.id,
               winning_attrs
             )

    assert retried == winner
  end

  defp append_attrs(design) do
    %{
      revision_id: Ecto.UUID.generate(),
      actor_ref: "device-owner",
      documents: SpecificationFixtures.documents(%{design: design})
    }
  end

  defp store_path do
    Path.join(
      System.tmp_dir!(),
      "specification_device_store_#{System.unique_integer([:positive])}/store.dets"
    )
  end
end
