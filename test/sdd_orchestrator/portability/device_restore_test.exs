defmodule SddOrchestrator.Portability.DeviceRestoreTest do
  @moduledoc """
  Task 19 proof for worker-owned, atomic, idempotent device restoration.
  """

  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.{DeviceStore.Local, Pairing}

  alias SddOrchestrator.Portability.{
    DeviceRestore,
    PackageProvenance,
    PackageSection,
    ProjectPackage,
    RestoreDecision
  }

  alias SddOrchestrator.Projects.Project
  alias SddOrchestrator.SpecificationFixtures
  alias SddOrchestrator.Specifications.{ProjectSpecification, SpecificationRevision}
  alias SddOrchestrator.SpecificationStore

  setup do
    path = store_path()
    on_exit(fn -> File.rm_rf!(Path.dirname(path)) end)
    start_supervised!({Local, path: path})
    {:ok, authority} = Devices.establish_workspace()
    pair_available_worker(authority.id)
    %{authority: authority, path: path}
  end

  test "atomically restores one device-authoritative aggregate without a hosted copy", %{
    authority: authority
  } do
    project_id = Ecto.UUID.generate()
    specification_id = Ecto.UUID.generate()

    package =
      package(project_id, "Device restore", "github", "8801", [
        specification(specification_id, "Device portability")
      ])

    restored_at = ~U[2026-07-28 19:00:00Z]

    assert {:ok, result} =
             DeviceRestore.restore(authority, package, decision(package, :device),
               idempotency_key: "device-restore-success",
               restored_at: restored_at
             )

    refute result.replay?
    assert result.project.id == project_id
    assert result.project.workspace_id == authority.id
    assert result.project.name == "Device restore"
    assert result.project.storage_mode == "device"
    assert result.project.status == "disconnected"
    assert result.project.repository_provider == "github"
    assert result.project.repository_id == "8801"
    assert is_nil(result.project.repository_fingerprint)

    assert result.provenance.project_id == project_id
    assert result.provenance.payload_schema_version == 1
    assert result.provenance.restored_at == restored_at

    assert {:ok, stored_project} = Devices.get_project(project_id)
    assert stored_project == result.project
    assert {:ok, stored_provenance} = Devices.get_package_provenance(project_id)
    assert stored_provenance == result.provenance

    assert {:ok, snapshot} = SpecificationStore.current_snapshot(authority, project_id)
    assert [restored_specification] = snapshot.specifications
    assert restored_specification.id == specification_id
    assert restored_specification.title == "Device portability"

    assert hosted_counts() == %{projects: 0, provenances: 0, specifications: 0, revisions: 0}
  end

  test "keeps a restored local identity disconnected while retaining its canonical fingerprint",
       %{authority: authority} do
    package = package(Ecto.UUID.generate(), "Local restore", "local", "fp-local-restore", [])

    assert {:ok, %{project: project}} =
             DeviceRestore.restore(authority, package, decision(package, :device),
               idempotency_key: "device-local-restore"
             )

    assert project.repository_provider == "local"
    assert project.repository_id == "fp-local-restore"
    assert project.repository_fingerprint == "fp-local-restore"
    assert project.status == "disconnected"
  end

  test "recovers a lost acknowledgement as an exact replay without duplicates", %{
    authority: authority
  } do
    package =
      package(Ecto.UUID.generate(), "Lost acknowledgement", "github", "8802", [
        specification(Ecto.UUID.generate(), "Retry")
      ])

    decision = decision(package, :device)

    assert {:error, :acknowledgement_lost} =
             DeviceRestore.restore(authority, package, decision,
               idempotency_key: "device-lost-ack",
               fault: :after_commit
             )

    assert {:ok, replay} =
             DeviceRestore.restore(authority, package, decision,
               idempotency_key: "device-lost-ack"
             )

    assert replay.replay?
    assert length(Devices.list_projects()) == 1
    assert Devices.specification_count(replay.project.id) == 1
    assert {:ok, _provenance} = Devices.get_package_provenance(replay.project.id)
    assert hosted_counts() == %{projects: 0, provenances: 0, specifications: 0, revisions: 0}
  end

  test "serializes concurrent exact restores into one device aggregate", %{authority: authority} do
    package =
      package(Ecto.UUID.generate(), "Concurrent device", "github", "8803", [
        specification(Ecto.UUID.generate(), "Concurrent")
      ])

    decision = decision(package, :device)

    results =
      1..2
      |> Task.async_stream(
        fn _attempt ->
          DeviceRestore.restore(authority, package, decision,
            idempotency_key: "device-concurrent"
          )
        end,
        max_concurrency: 2,
        ordered: false,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?({:ok, _success}, &1))
    assert length(Devices.list_projects()) == 1
    assert Devices.specification_count(package.project.content["id"]) == 1
  end

  test "a different aggregate with an existing stable identity is not a replay", %{
    authority: authority
  } do
    project_id = Ecto.UUID.generate()
    original = package(project_id, "Original device", "github", "8804", [])

    assert {:ok, _result} =
             DeviceRestore.restore(authority, original, decision(original, :device),
               idempotency_key: "device-original"
             )

    changed = package(project_id, "Changed device", "github", "8804", [])

    assert {:error, :identity_conflict} =
             DeviceRestore.restore(authority, changed, decision(changed, :device),
               idempotency_key: "device-changed"
             )

    assert {:ok, unchanged} = Devices.get_project(project_id)
    assert unchanged.name == "Original device"
    assert length(Devices.list_projects()) == 1
  end

  test "device name and repository checks arbitrate stale preflight with repository precedence",
       %{authority: authority} do
    {:ok, existing} =
      Devices.register_project(%{
        name: "Existing device",
        repository_fingerprint: "fp-existing-device",
        status: "connected"
      })

    name_package =
      package(Ecto.UUID.generate(), "existing DEVICE", "local", "fp-other-device", [])

    assert {:error, :name_conflict} =
             DeviceRestore.restore(authority, name_package, decision(name_package, :device),
               idempotency_key: "device-name-race"
             )

    repository_package =
      package(Ecto.UUID.generate(), "EXISTING DEVICE", "local", "fp-existing-device", [])

    assert {:error, :repository_conflict} =
             DeviceRestore.restore(
               authority,
               repository_package,
               decision(repository_package, :device),
               idempotency_key: "device-repository-race"
             )

    assert {:ok, unchanged} = Devices.get_project(existing.id)
    assert unchanged.name == "Existing device"
    assert length(Devices.list_projects()) == 1
  end

  test "a global device specification identity collision rolls back the new project", %{
    authority: authority
  } do
    {:ok, existing_project} =
      Devices.register_project(%{
        name: "Existing specification owner",
        repository_fingerprint: "fp-existing-specification",
        status: "connected"
      })

    attrs = SpecificationFixtures.specification_attrs()

    assert {:ok, current} =
             SpecificationStore.create(authority, existing_project.id, attrs)

    package =
      package(Ecto.UUID.generate(), "Specification collision", "github", "8805", [
        specification(current.specification.id, "Conflicting identity")
      ])

    assert {:error, :specification_conflict} =
             DeviceRestore.restore(authority, package, decision(package, :device),
               idempotency_key: "device-specification-conflict"
             )

    assert length(Devices.list_projects()) == 1

    assert {:error, :not_found} =
             Devices.get_package_provenance(package.project.content["id"])
  end

  test "faults at each worker-owned stage leave no project, provenance, or specification", %{
    authority: authority
  } do
    Enum.each([:after_project, :after_provenance, :after_specification], fn fault ->
      package =
        package(Ecto.UUID.generate(), "Fault #{fault}", "github", repository_id(fault), [
          specification(Ecto.UUID.generate(), "Fault")
        ])

      assert {:error, :injected_failure} =
               DeviceRestore.restore(authority, package, decision(package, :device),
                 idempotency_key: "device-fault-#{fault}",
                 fault: fault
               )

      assert Devices.list_projects() == []
      assert Devices.specification_count(package.project.content["id"]) == 0

      assert {:error, :not_found} =
               Devices.get_package_provenance(package.project.content["id"])
    end)
  end

  test "persists the full device aggregate across a worker-store restart", %{
    authority: authority,
    path: path
  } do
    package =
      package(Ecto.UUID.generate(), "Durable restore", "github", "8806", [
        specification(Ecto.UUID.generate(), "Durable specification")
      ])

    assert {:ok, first} =
             DeviceRestore.restore(authority, package, decision(package, :device),
               idempotency_key: "device-durable"
             )

    stop_supervised!(Local)
    start_supervised!({Local, path: path})

    assert {:ok, restored_authority} = Devices.get_workspace()
    assert restored_authority.id == authority.id
    assert {:ok, project} = Devices.get_project(first.project.id)
    assert project == first.project
    assert {:ok, provenance} = Devices.get_package_provenance(first.project.id)
    assert provenance == first.provenance
    assert {:ok, snapshot} = SpecificationStore.current_snapshot(authority, first.project.id)
    assert length(snapshot.specifications) == 1
  end

  test "rejects forged package decisions and unavailable device authority", %{
    authority: authority
  } do
    package = package(Ecto.UUID.generate(), "Forged device", "github", "8807", [])
    forged = %{decision(package, :device) | repository_id: "different"}

    assert {:error, :invalid_restore} =
             DeviceRestore.restore(authority, package, forged, idempotency_key: "device-forged")

    [worker] = Pairing.active_workers(authority.id)
    assert {:ok, _revoked} = Pairing.revoke_worker(worker)

    assert {:error, :destination_unavailable} =
             DeviceRestore.restore(authority, package, decision(package, :device),
               idempotency_key: "device-unavailable"
             )

    assert Devices.list_projects() == []
  end

  defp package(project_id, name, provider, repository_id, specifications) do
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
        content: specifications
      }
    }
  end

  defp specification(id, title) do
    %{
      "id" => id,
      "title" => title,
      "requirements" => "# Requirements",
      "design" => "# Design",
      "tasks" => "# Tasks"
    }
  end

  defp decision(package, boundary) do
    %RestoreDecision{
      project_id: package.project.content["id"],
      display_name: String.trim(package.project.content["name"]),
      repository_provider: package.repository.content["provider"],
      repository_id: package.repository.content["repository_id"],
      checked_boundaries: [boundary]
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

  defp hosted_counts do
    %{
      projects: Repo.aggregate(Project, :count),
      provenances: Repo.aggregate(PackageProvenance, :count),
      specifications: Repo.aggregate(ProjectSpecification, :count),
      revisions: Repo.aggregate(SpecificationRevision, :count)
    }
  end

  defp repository_id(:after_project), do: "8810"
  defp repository_id(:after_provenance), do: "8811"
  defp repository_id(:after_specification), do: "8812"

  defp store_path do
    dir = Path.join(System.tmp_dir!(), "sdd_device_restore_#{System.unique_integer([:positive])}")
    Path.join(dir, "store.dets")
  end
end
