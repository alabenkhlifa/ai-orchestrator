defmodule SddOrchestrator.Portability.HostedRestoreTest do
  @moduledoc """
  Task 12 proof for atomic, constraint-backed, idempotent hosted restoration.
  """

  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.AccountsFixtures

  alias SddOrchestrator.Portability.{
    HostedRestore,
    PackageProvenance,
    PackageSection,
    ProjectPackage,
    RestoreDecision
  }

  alias SddOrchestrator.Projects
  alias SddOrchestrator.Projects.Project
  alias SddOrchestrator.ProjectsFixtures
  alias SddOrchestrator.ProjectStorage.HostedProjectStorage
  alias SddOrchestrator.SpecificationFixtures
  alias SddOrchestrator.Specifications.{ProjectSpecification, SpecificationRevision}
  alias SddOrchestrator.SpecificationStore

  setup do
    account = AccountsFixtures.account_fixture()
    %{authority: ProjectsFixtures.workspace_fixture(account)}
  end

  test "atomically restores the stable project, repository, specifications, and minimal provenance",
       %{authority: authority} do
    project_id = Ecto.UUID.generate()
    specification_id = Ecto.UUID.generate()

    package =
      package(project_id, "Restored project", "github", "7401", [
        specification(specification_id, "Portability")
      ])

    restored_at = ~U[2026-07-28 18:30:00Z]

    assert {:ok, result} =
             HostedRestore.restore(authority, package, decision(package),
               idempotency_key: "restore-success",
               restored_at: restored_at
             )

    refute result.replay?
    assert result.project.id == project_id
    assert result.project.name == "Restored project"
    assert result.project.storage_mode == "hosted"
    assert result.project.lifecycle_state == "active"
    assert result.project.repository_provider == "github"
    assert result.project.canonical_repository_id == "7401"
    assert is_nil(result.project.repository_connection)
    assert result.project.hosted_storage.root == "hosted/" <> project_id
    assert result.project.hosted_storage.state == "ready"

    assert result.provenance.project_id == project_id
    assert result.provenance.payload_schema_version == 1
    assert result.provenance.restored_at == restored_at

    assert PackageProvenance.__schema__(:fields) ==
             [:project_id, :payload_schema_version, :restored_at]

    assert {:ok, snapshot} = SpecificationStore.current_snapshot(authority, project_id)
    assert [restored_specification] = snapshot.specifications
    assert restored_specification.id == specification_id
    assert restored_specification.title == "Portability"
    assert restored_specification.requirements == "# Requirements"
    assert restored_specification.design == "# Design"
    assert restored_specification.tasks == "# Tasks"

    assert counts() == %{
             projects: 1,
             storages: 1,
             provenances: 1,
             specifications: 1,
             revisions: 1
           }
  end

  test "restores a local canonical repository identity into hosted storage without a connection",
       %{authority: authority} do
    package = package(Ecto.UUID.generate(), "Local source", "local", "fp-local-source", [])

    assert {:ok, %{project: project}} =
             HostedRestore.restore(authority, package, decision(package),
               idempotency_key: "restore-local-source"
             )

    assert project.repository_provider == "local"
    assert project.canonical_repository_id == "fp-local-source"
    assert is_nil(project.repository_connection)
    assert Repo.aggregate(Project, :count) == 1
  end

  test "an exact replay returns the same aggregate without duplicate persistence", %{
    authority: authority
  } do
    package =
      package(Ecto.UUID.generate(), "Replay", "github", "7402", [
        specification(Ecto.UUID.generate(), "Replay spec")
      ])

    decision = decision(package)

    assert {:ok, first} =
             HostedRestore.restore(authority, package, decision,
               idempotency_key: "restore-replay"
             )

    assert {:ok, replay} =
             HostedRestore.restore(authority, package, decision,
               idempotency_key: "restore-replay"
             )

    refute first.replay?
    assert replay.replay?
    assert replay.project.id == first.project.id

    assert Enum.map(replay.specifications, & &1.revision_id) ==
             Enum.map(first.specifications, fn current -> current.revision.id end)

    assert counts() == %{
             projects: 1,
             storages: 1,
             provenances: 1,
             specifications: 1,
             revisions: 1
           }
  end

  test "a concurrent exact replay commits one aggregate", %{authority: authority} do
    package =
      package(Ecto.UUID.generate(), "Concurrent", "github", "7403", [
        specification(Ecto.UUID.generate(), "Concurrent spec")
      ])

    decision = decision(package)

    results =
      1..2
      |> Task.async_stream(
        fn _attempt ->
          HostedRestore.restore(authority, package, decision,
            idempotency_key: "restore-concurrent"
          )
        end,
        max_concurrency: 2,
        ordered: false,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?({:ok, _result}, &1))

    assert counts() == %{
             projects: 1,
             storages: 1,
             provenances: 1,
             specifications: 1,
             revisions: 1
           }
  end

  test "a different aggregate with an existing stable identity is not a replay", %{
    authority: authority
  } do
    project_id = Ecto.UUID.generate()
    original = package(project_id, "Original", "github", "7404", [])

    assert {:ok, _result} =
             HostedRestore.restore(authority, original, decision(original),
               idempotency_key: "restore-original"
             )

    changed = package(project_id, "Changed", "github", "7404", [])

    assert {:error, :identity_conflict} =
             HostedRestore.restore(authority, changed, decision(changed),
               idempotency_key: "restore-changed"
             )

    assert Projects.get_project(authority, project_id).name == "Original"
    assert Repo.aggregate(Project, :count) == 1
  end

  test "database name and canonical repository constraints arbitrate stale preflight races", %{
    authority: authority
  } do
    existing =
      ProjectsFixtures.registered_project(authority,
        name: "Existing",
        repository: ProjectsFixtures.repository_metadata(id: 7405)
      )

    name_package = package(Ecto.UUID.generate(), "existing", "github", "7406", [])

    assert {:error, :name_conflict} =
             HostedRestore.restore(authority, name_package, decision(name_package),
               idempotency_key: "restore-name-race"
             )

    repository_package = package(Ecto.UUID.generate(), "Available", "github", "7405", [])

    assert {:error, :repository_conflict} =
             HostedRestore.restore(authority, repository_package, decision(repository_package),
               idempotency_key: "restore-repository-race"
             )

    assert Repo.get!(Project, existing.id).name == "Existing"
    assert Repo.aggregate(Project, :count) == 1
    assert Repo.aggregate(PackageProvenance, :count) == 0
  end

  test "a specification identity collision rolls back the entire aggregate", %{
    authority: authority
  } do
    existing_project = ProjectsFixtures.project_fixture(authority)

    assert {:ok, current} =
             SpecificationStore.create(
               authority,
               existing_project.id,
               SpecificationFixtures.specification_attrs(title: "Existing specification")
             )

    package =
      package(Ecto.UUID.generate(), "Collision", "github", "7407", [
        specification(current.specification.id, "Colliding specification")
      ])

    before = counts()

    assert {:error, :specification_conflict} =
             HostedRestore.restore(authority, package, decision(package),
               idempotency_key: "restore-specification-conflict"
             )

    assert counts() == before
  end

  test "faults after every owned transaction stage leave no partial aggregate", %{
    authority: authority
  } do
    Enum.each(
      [:after_project, :after_storage, :after_provenance, :after_specification],
      fn fault ->
        package =
          package(Ecto.UUID.generate(), "Fault #{fault}", "github", repository_id(fault), [
            specification(Ecto.UUID.generate(), "Fault spec")
          ])

        assert {:error, :injected_failure} =
                 HostedRestore.restore(authority, package, decision(package),
                   idempotency_key: "restore-fault-#{fault}",
                   fault: fault
                 )

        assert counts() == %{
                 projects: 0,
                 storages: 0,
                 provenances: 0,
                 specifications: 0,
                 revisions: 0
               }
      end
    )
  end

  test "rejects a forged decision and a missing hosted authority", %{authority: authority} do
    package = package(Ecto.UUID.generate(), "Forged", "github", "7408", [])
    forged = %{decision(package) | repository_id: "different"}

    assert {:error, :invalid_restore} =
             HostedRestore.restore(authority, package, forged, idempotency_key: "restore-forged")

    missing_authority = %{authority | id: Ecto.UUID.generate()}

    assert {:error, :not_found} =
             HostedRestore.restore(missing_authority, package, decision(package),
               idempotency_key: "restore-missing-authority"
             )
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

  defp decision(package) do
    %RestoreDecision{
      project_id: package.project.content["id"],
      display_name: String.trim(package.project.content["name"]),
      repository_provider: package.repository.content["provider"],
      repository_id: package.repository.content["repository_id"],
      checked_boundaries: [:hosted]
    }
  end

  defp counts do
    %{
      projects: Repo.aggregate(Project, :count),
      storages: Repo.aggregate(HostedProjectStorage, :count),
      provenances: Repo.aggregate(PackageProvenance, :count),
      specifications: Repo.aggregate(ProjectSpecification, :count),
      revisions: Repo.aggregate(SpecificationRevision, :count)
    }
  end

  defp repository_id(:after_project), do: "7410"
  defp repository_id(:after_storage), do: "7411"
  defp repository_id(:after_provenance), do: "7412"
  defp repository_id(:after_specification), do: "7413"
end
