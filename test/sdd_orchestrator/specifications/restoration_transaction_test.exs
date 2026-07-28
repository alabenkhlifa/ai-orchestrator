defmodule SddOrchestrator.Specifications.RestorationTransactionTest do
  use SddOrchestrator.DataCase, async: false

  alias Ecto.Multi
  alias SddOrchestrator.Accounts.DeviceWorkspace
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.{DeviceStore.Local, DeviceTransaction}
  alias SddOrchestrator.Projects.Project
  alias SddOrchestrator.SpecificationStore

  alias SddOrchestrator.Specifications.{
    ProjectSpecification,
    SpecificationRevision,
    SpecificationSnapshot
  }

  alias SddOrchestrator.{AccountsFixtures, ProjectsFixtures, SpecificationFixtures}

  setup do
    account = AccountsFixtures.account_fixture()
    workspace = ProjectsFixtures.workspace_fixture(account)
    path = store_path()
    on_exit(fn -> File.rm_rf!(Path.dirname(path)) end)
    start_supervised!({Local, path: path})
    {:ok, device_workspace} = Devices.establish_workspace()

    %{device_workspace: device_workspace, workspace: workspace}
  end

  test "contributes preserved hosted identities to the caller project transaction", context do
    project_id = Ecto.UUID.generate()

    values =
      restore_values(2)
      |> Enum.map(&struct(SpecificationSnapshot.Entry, &1))

    key = Ecto.UUID.generate()

    transaction = hosted_project_transaction(context.workspace, project_id, "Restored")

    assert {:ok, prepared} =
             SpecificationStore.prepare_restore(
               context.workspace,
               transaction,
               values,
               idempotency_key: key
             )

    assert {:ok, changes} = Repo.transaction(prepared)
    assert changes.project.id == project_id

    assert Enum.map(changes[{:specification_restore, key}], fn current ->
             {current.specification.id, current.revision.id}
           end) ==
             values
             |> Enum.sort_by(& &1.id)
             |> Enum.map(&{&1.id, &1.revision_id})

    assert Repo.aggregate(ProjectSpecification, :count) == 2
    assert Repo.aggregate(SpecificationRevision, :count) == 2
  end

  test "makes hosted preparation and a committed replay idempotent", context do
    project_id = Ecto.UUID.generate()
    values = restore_values(1)
    key = Ecto.UUID.generate()
    transaction = hosted_project_transaction(context.workspace, project_id, "Replay")

    assert {:ok, prepared} =
             SpecificationStore.prepare_restore(
               context.workspace,
               transaction,
               values,
               idempotency_key: key
             )

    assert {:ok, same_prepared} =
             SpecificationStore.prepare_restore(
               context.workspace,
               prepared,
               values,
               idempotency_key: key
             )

    assert same_prepared == prepared
    assert {:ok, _changes} = Repo.transaction(prepared)

    replay =
      Multi.new()
      |> Multi.run(:project, fn repo, _changes ->
        {:ok, repo.get!(Project, project_id)}
      end)

    assert {:ok, replay} =
             SpecificationStore.prepare_restore(
               context.workspace,
               replay,
               values,
               idempotency_key: key
             )

    assert {:ok, changes} = Repo.transaction(replay)
    assert [current] = changes[{:specification_restore, key}]
    assert current.specification.id == hd(values).id
    assert Repo.aggregate(ProjectSpecification, :count) == 1
    assert Repo.aggregate(SpecificationRevision, :count) == 1

    changed = [Map.put(hd(values), :title, "Different")]

    assert {:error, :restore_conflict} =
             SpecificationStore.prepare_restore(
               context.workspace,
               prepared,
               changed,
               idempotency_key: key
             )
  end

  test "rolls back the hosted project and every specification on conflict or injected failure",
       context do
    existing_project = ProjectsFixtures.registered_project(context.workspace)
    [conflicting] = restore_values(1)

    assert {:ok, _current} =
             SpecificationStore.create(
               context.workspace,
               existing_project.id,
               specification_attrs(conflicting)
             )

    conflict_project_id = Ecto.UUID.generate()

    conflict_transaction =
      hosted_project_transaction(context.workspace, conflict_project_id, "Conflict")

    assert {:ok, conflict_transaction} =
             SpecificationStore.prepare_restore(
               context.workspace,
               conflict_transaction,
               [conflicting],
               idempotency_key: Ecto.UUID.generate()
             )

    assert {:error, _operation, :specification_conflict, _changes} =
             Repo.transaction(conflict_transaction)

    refute Repo.get(Project, conflict_project_id)
    assert Repo.aggregate(ProjectSpecification, :count) == 1
    assert Repo.aggregate(SpecificationRevision, :count) == 1

    failure_project_id = Ecto.UUID.generate()

    failure_transaction =
      hosted_project_transaction(context.workspace, failure_project_id, "Failure")

    assert {:ok, failure_transaction} =
             SpecificationStore.prepare_restore(
               context.workspace,
               failure_transaction,
               restore_values(2),
               idempotency_key: Ecto.UUID.generate(),
               fault: :after_specification
             )

    assert {:error, _operation, :injected_failure, _changes} =
             Repo.transaction(failure_transaction)

    refute Repo.get(Project, failure_project_id)
    assert Repo.aggregate(ProjectSpecification, :count) == 1
    assert Repo.aggregate(SpecificationRevision, :count) == 1
  end

  test "contributes and commits one preserved device specification batch without a hosted copy",
       context do
    project = device_project("device-restore")
    {:ok, transaction} = DeviceTransaction.new(project.id)
    values = restore_values(2)
    key = Ecto.UUID.generate()

    assert {:ok, prepared} =
             SpecificationStore.prepare_restore(
               context.device_workspace,
               transaction,
               values,
               idempotency_key: key
             )

    assert {:ok, %{specification_restore: restored}} =
             Devices.commit_transaction(prepared)

    assert Enum.map(restored, fn current ->
             {current.specification.id, current.revision.id}
           end) ==
             values
             |> Enum.sort_by(& &1.id)
             |> Enum.map(&{&1.id, &1.revision_id})

    assert {:ok, %{specification_restore: replayed}} =
             Devices.commit_transaction(prepared)

    assert replayed == restored
    assert Devices.specification_count(project.id) == 2
    assert Repo.aggregate(ProjectSpecification, :count) == 0
    assert Repo.aggregate(SpecificationRevision, :count) == 0
  end

  test "keeps the device transaction unchanged on conflict and injected failure", context do
    conflict_project = device_project("device-conflict")
    [existing] = restore_values(1)

    assert {:ok, _current} =
             SpecificationStore.create(
               context.device_workspace,
               conflict_project.id,
               specification_attrs(existing)
             )

    {:ok, conflict_transaction} = DeviceTransaction.new(conflict_project.id)

    assert {:ok, conflict_transaction} =
             SpecificationStore.prepare_restore(
               context.device_workspace,
               conflict_transaction,
               [Map.put(existing, :title, "Changed")],
               idempotency_key: Ecto.UUID.generate()
             )

    assert {:error, :specification_conflict} =
             Devices.commit_transaction(conflict_transaction)

    assert Devices.specification_count(conflict_project.id) == 1

    failure_project = device_project("device-failure")
    {:ok, failure_transaction} = DeviceTransaction.new(failure_project.id)

    assert {:ok, failure_transaction} =
             SpecificationStore.prepare_restore(
               context.device_workspace,
               failure_transaction,
               restore_values(2),
               idempotency_key: Ecto.UUID.generate(),
               fault: :after_specification
             )

    assert {:error, :injected_failure} =
             Devices.commit_transaction(failure_transaction)

    assert Devices.specification_count(failure_project.id) == 0
  end

  test "rejects malformed, duplicate, foreign, and conflicting transaction contributions",
       context do
    project = device_project("device-invalid")
    {:ok, transaction} = DeviceTransaction.new(project.id)
    [value] = restore_values(1)
    key = Ecto.UUID.generate()

    assert {:error, :invalid_restore} =
             SpecificationStore.prepare_restore(
               context.device_workspace,
               transaction,
               [Map.put(value, :path, "../requirements.md")],
               idempotency_key: key
             )

    assert {:error, :specification_conflict} =
             SpecificationStore.prepare_restore(
               context.device_workspace,
               transaction,
               [value, value],
               idempotency_key: key
             )

    assert {:ok, prepared} =
             SpecificationStore.prepare_restore(
               context.device_workspace,
               transaction,
               [value],
               idempotency_key: key
             )

    assert {:ok, ^prepared} =
             SpecificationStore.prepare_restore(
               context.device_workspace,
               prepared,
               [value],
               idempotency_key: key
             )

    assert {:error, :restore_conflict} =
             SpecificationStore.prepare_restore(
               context.device_workspace,
               prepared,
               [Map.put(value, :title, "Changed")],
               idempotency_key: key
             )

    assert {:error, :not_found} =
             SpecificationStore.prepare_restore(
               %DeviceWorkspace{id: Ecto.UUID.generate()},
               transaction,
               [value],
               idempotency_key: key
             )

    assert Devices.specification_count(project.id) == 0
  end

  defp hosted_project_transaction(workspace, project_id, name) do
    changeset =
      Project.registration_changeset(
        %Project{id: project_id},
        %{
          name: name,
          workspace_id: workspace.id,
          storage_mode: "hosted",
          lifecycle_state: "active"
        }
      )

    Multi.insert(Multi.new(), :project, changeset)
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

  defp restore_values(count) do
    for index <- 1..count do
      attrs =
        SpecificationFixtures.specification_attrs(
          title: "Restored #{index}",
          documents: SpecificationFixtures.documents(%{design: "design #{index}"})
        )

      %{
        id: attrs.id,
        title: attrs.title,
        revision_id: attrs.revision_id,
        requirements: attrs.documents.requirements,
        design: attrs.documents.design,
        tasks: attrs.documents.tasks
      }
    end
  end

  defp specification_attrs(value) do
    %{
      id: value.id,
      title: value.title,
      revision_id: value.revision_id,
      documents: %{
        requirements: value.requirements,
        design: value.design,
        tasks: value.tasks
      }
    }
  end

  defp store_path do
    Path.join(
      System.tmp_dir!(),
      "restoration_device_store_#{System.unique_integer([:positive])}/store.dets"
    )
  end
end
