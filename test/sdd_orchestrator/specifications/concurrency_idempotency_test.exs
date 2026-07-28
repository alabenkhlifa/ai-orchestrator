defmodule SddOrchestrator.Specifications.ConcurrencyIdempotencyTest do
  use SddOrchestrator.DataCase, async: false

  alias Ecto.Multi
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.{DeviceStore.Local, DeviceTransaction}
  alias SddOrchestrator.SpecificationStore

  alias SddOrchestrator.Specifications.{
    ProjectSpecification,
    SpecificationRevision
  }

  alias SddOrchestrator.{AccountsFixtures, ProjectsFixtures, SpecificationFixtures}

  setup do
    account = AccountsFixtures.account_fixture()
    workspace = ProjectsFixtures.workspace_fixture(account)
    hosted_project = ProjectsFixtures.registered_project(workspace)
    path = store_path()
    on_exit(fn -> File.rm_rf!(Path.dirname(path)) end)
    start_supervised!({Local, path: path})
    {:ok, device_workspace} = Devices.establish_workspace()
    device_project = device_project("concurrency-device")

    %{
      device_project: device_project,
      device_workspace: device_workspace,
      hosted_project: hosted_project,
      workspace: workspace
    }
  end

  test "concurrent identical hosted creates converge and conflicting reuse cannot win", context do
    attrs = SpecificationFixtures.specification_attrs()

    results =
      1..2
      |> Task.async_stream(
        fn _request ->
          SpecificationStore.create(
            context.workspace,
            context.hosted_project.id,
            attrs,
            actor_ref: "owner"
          )
        end,
        max_concurrency: 2
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?({:ok, _current}, &1))

    assert results
           |> Enum.map(fn {:ok, current} ->
             {current.specification.id, current.revision.id}
           end)
           |> Enum.uniq() == [{attrs.id, attrs.revision_id}]

    conflicting =
      put_in(attrs.documents.design, "conflicting committed retry")

    assert {:error, %Ecto.Changeset{}} =
             SpecificationStore.create(
               context.workspace,
               context.hosted_project.id,
               conflicting,
               actor_ref: "owner"
             )

    assert Repo.aggregate(ProjectSpecification, :count) == 1
    assert Repo.aggregate(SpecificationRevision, :count) == 1
  end

  test "concurrent identical device creates converge without a hosted copy", context do
    attrs = SpecificationFixtures.specification_attrs()

    results =
      1..2
      |> Task.async_stream(
        fn _request ->
          SpecificationStore.create(
            context.device_workspace,
            context.device_project.id,
            attrs,
            actor_ref: "owner"
          )
        end,
        max_concurrency: 2
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?({:ok, _current}, &1))
    assert Devices.specification_count(context.device_project.id) == 1

    conflicting =
      put_in(attrs.documents.tasks, "conflicting committed retry")

    assert {:error, :specification_conflict} =
             SpecificationStore.create(
               context.device_workspace,
               context.device_project.id,
               conflicting,
               actor_ref: "owner"
             )

    assert Repo.aggregate(ProjectSpecification, :count) == 0
    assert Repo.aggregate(SpecificationRevision, :count) == 0
  end

  test "hosted create and restore races preserve one aggregate and both retry idempotently",
       context do
    attrs = SpecificationFixtures.specification_attrs()
    [value] = restore_values(attrs)
    key = Ecto.UUID.generate()

    project_transaction =
      Multi.run(Multi.new(), :project, fn _repo, _changes ->
        {:ok, context.hosted_project}
      end)

    assert {:ok, restore_transaction} =
             SpecificationStore.prepare_restore(
               context.workspace,
               project_transaction,
               [value],
               idempotency_key: key
             )

    create_task =
      Task.async(fn ->
        SpecificationStore.create(context.workspace, context.hosted_project.id, attrs)
      end)

    restore_task = Task.async(fn -> Repo.transaction(restore_transaction) end)

    initial_results = [Task.await(create_task), Task.await(restore_task)]
    assert Enum.any?(initial_results, &match?({:ok, _result}, &1))
    assert Repo.aggregate(ProjectSpecification, :count) == 1
    assert Repo.aggregate(SpecificationRevision, :count) == 1

    assert {:ok, created} =
             SpecificationStore.create(context.workspace, context.hosted_project.id, attrs)

    assert {:ok, replayed} = Repo.transaction(restore_transaction)
    assert created.specification.id == value.id
    assert [restored] = replayed[{:specification_restore, key}]
    assert restored.specification.id == value.id
    assert Repo.aggregate(ProjectSpecification, :count) == 1
    assert Repo.aggregate(SpecificationRevision, :count) == 1
  end

  test "device create and restore races serialize to one equivalent aggregate", context do
    attrs = SpecificationFixtures.specification_attrs()
    [value] = restore_values(attrs)
    {:ok, transaction} = DeviceTransaction.new(context.device_project.id)

    assert {:ok, transaction} =
             SpecificationStore.prepare_restore(
               context.device_workspace,
               transaction,
               [value],
               idempotency_key: Ecto.UUID.generate()
             )

    results =
      [
        fn ->
          SpecificationStore.create(
            context.device_workspace,
            context.device_project.id,
            attrs
          )
        end,
        fn -> Devices.commit_transaction(transaction) end
      ]
      |> Task.async_stream(fn operation -> operation.() end, max_concurrency: 2)
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?({:ok, _result}, &1))
    assert Devices.specification_count(context.device_project.id) == 1
  end

  test "append writers and a current snapshot share one complete commit boundary", context do
    attrs = SpecificationFixtures.specification_attrs()

    assert {:ok, current} =
             SpecificationStore.create(context.workspace, context.hosted_project.id, attrs)

    appends =
      for marker <- ["writer-one", "writer-two"] do
        %{
          revision_id: Ecto.UUID.generate(),
          documents:
            SpecificationFixtures.documents(%{
              requirements: marker,
              design: marker,
              tasks: marker
            })
        }
      end

    tasks =
      Enum.map(appends, fn append ->
        Task.async(fn ->
          SpecificationStore.append_revision(
            context.workspace,
            context.hosted_project.id,
            current.specification.id,
            current.revision.id,
            append
          )
        end)
      end)

    assert {:ok, snapshot} =
             SpecificationStore.current_snapshot(context.workspace, context.hosted_project.id)

    results = Enum.map(tasks, &Task.await/1)
    assert Enum.count(results, &match?({:ok, _result}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :stale_revision})) == 1

    [entry] = snapshot.specifications

    assert {entry.requirements, entry.design, entry.tasks} in [
             {
               attrs.documents.requirements,
               attrs.documents.design,
               attrs.documents.tasks
             },
             {"writer-one", "writer-one", "writer-one"},
             {"writer-two", "writer-two", "writer-two"}
           ]

    assert Repo.aggregate(ProjectSpecification, :count) == 1
    assert Repo.aggregate(SpecificationRevision, :count) == 2
  end

  defp device_project(fingerprint) do
    {:ok, project} =
      Devices.register_project(%{
        name: fingerprint,
        repository_fingerprint: fingerprint,
        status: "connected",
        idempotency_key: Ecto.UUID.generate()
      })

    project
  end

  defp restore_values(attrs) do
    [
      %{
        id: attrs.id,
        title: attrs.title,
        revision_id: attrs.revision_id,
        requirements: attrs.documents.requirements,
        design: attrs.documents.design,
        tasks: attrs.documents.tasks
      }
    ]
  end

  defp store_path do
    Path.join(
      System.tmp_dir!(),
      "specification_concurrency_store_#{System.unique_integer([:positive])}/store.dets"
    )
  end
end
