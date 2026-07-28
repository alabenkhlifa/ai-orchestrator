defmodule SddOrchestrator.Specifications.HostedStoreTest do
  use SddOrchestrator.DataCase, async: false

  import Ecto.Query

  alias SddOrchestrator.SpecificationStore

  alias SddOrchestrator.Specifications.{
    ProjectSpecification,
    SpecificationDocuments,
    SpecificationRevision
  }

  alias SddOrchestrator.{AccountsFixtures, ProjectsFixtures, SpecificationFixtures}

  setup do
    account = AccountsFixtures.account_fixture()
    workspace = ProjectsFixtures.workspace_fixture(account)
    project = ProjectsFixtures.registered_project(workspace)
    %{workspace: workspace, project: project}
  end

  test "creates one stable specification and first immutable revision atomically", context do
    attrs = SpecificationFixtures.specification_attrs(title: "  Refund approval  ")

    assert {:ok, %{specification: specification, revision: revision}} =
             SpecificationStore.create(
               context.workspace,
               context.project.id,
               attrs,
               actor_ref: "owner-1"
             )

    assert specification.id == attrs.id
    assert specification.project_id == context.project.id
    assert specification.title == "Refund approval"
    assert specification.current_revision_id == attrs.revision_id

    assert revision.id == attrs.revision_id
    assert revision.specification_id == specification.id
    assert revision.project_id == context.project.id
    assert revision.sequence == 1
    assert revision.actor_ref == "owner-1"
    assert revision.requirements_document == attrs.documents.requirements
    assert revision.design_document == attrs.documents.design
    assert revision.tasks_document == attrs.documents.tasks
    assert revision.content_digest == SpecificationDocuments.digest(attrs.documents)

    assert Repo.aggregate(ProjectSpecification, :count) == 1
    assert Repo.aggregate(SpecificationRevision, :count) == 1
  end

  test "returns only the authorized specification and its current complete revision", context do
    current = SpecificationFixtures.hosted_specification(context.workspace, context.project)

    assert {:ok, fetched} =
             SpecificationStore.get_current(
               context.workspace,
               context.project.id,
               current.specification.id
             )

    assert fetched.specification.id == current.specification.id
    assert fetched.revision.id == current.revision.id
    assert fetched.revision.requirements_document == current.revision.requirements_document
  end

  test "fails closed for another workspace, project, or malformed identity", context do
    current = SpecificationFixtures.hosted_specification(context.workspace, context.project)
    other_account = AccountsFixtures.account_fixture()
    other_workspace = ProjectsFixtures.workspace_fixture(other_account)
    other_project = ProjectsFixtures.registered_project(other_workspace)

    assert {:error, :not_found} =
             SpecificationStore.get_current(
               other_workspace,
               context.project.id,
               current.specification.id
             )

    assert {:error, :not_found} =
             SpecificationStore.get_current(
               context.workspace,
               other_project.id,
               current.specification.id
             )

    assert {:error, :not_found} =
             SpecificationStore.get_current(context.workspace, context.project.id, "invalid")

    attrs = SpecificationFixtures.specification_attrs()

    assert {:error, :not_found} =
             SpecificationStore.create(other_workspace, context.project.id, attrs)
  end

  test "rejects incomplete, unsupported, and oversized document sets without persistence",
       context do
    incomplete =
      SpecificationFixtures.specification_attrs(
        documents: Map.delete(SpecificationFixtures.documents(), :tasks)
      )

    assert {:error, :invalid_document_set} =
             SpecificationStore.create(context.workspace, context.project.id, incomplete)

    unsupported =
      SpecificationFixtures.specification_attrs(
        documents: Map.put(SpecificationFixtures.documents(), :path, "../requirements.md")
      )

    assert {:error, :invalid_document_set} =
             SpecificationStore.create(context.workspace, context.project.id, unsupported)

    oversized =
      SpecificationFixtures.specification_attrs(
        documents:
          SpecificationFixtures.documents(%{
            requirements: String.duplicate("x", 256 * 1_024 + 1)
          })
      )

    assert {:error, :document_too_large} =
             SpecificationStore.create(context.workspace, context.project.id, oversized)

    assert Repo.aggregate(ProjectSpecification, :count) == 0
    assert Repo.aggregate(SpecificationRevision, :count) == 0
  end

  test "enforces configured project and actor-reference limits", context do
    previous_limits = Application.get_env(:sdd_orchestrator, :specification_limits)

    on_exit(fn ->
      Application.put_env(:sdd_orchestrator, :specification_limits, previous_limits)
    end)

    Application.put_env(
      :sdd_orchestrator,
      :specification_limits,
      Keyword.put(previous_limits, :max_specifications_per_project, 1)
    )

    assert {:ok, _current} =
             SpecificationStore.create(
               context.workspace,
               context.project.id,
               SpecificationFixtures.specification_attrs()
             )

    assert {:error, :specification_limit_exceeded} =
             SpecificationStore.create(
               context.workspace,
               context.project.id,
               SpecificationFixtures.specification_attrs()
             )

    other_project =
      ProjectsFixtures.registered_project(context.workspace,
        name: "Other",
        repository: ProjectsFixtures.repository_metadata(id: 202)
      )

    assert {:error, %Ecto.Changeset{} = changeset} =
             SpecificationStore.create(
               context.workspace,
               other_project.id,
               SpecificationFixtures.specification_attrs(),
               actor_ref: "owner@example.test"
             )

    assert "must be a non-email reference" in errors_on(changeset).actor_ref

    refute Repo.exists?(
             from revision in SpecificationRevision,
               where: revision.project_id == ^other_project.id
           )
  end

  test "stores hostile-looking text as inert document content", context do
    command = "$(touch /tmp/should-never-run) && ../private/key"

    attrs =
      SpecificationFixtures.specification_attrs(
        documents: SpecificationFixtures.documents(%{design: command})
      )

    assert {:ok, %{revision: revision}} =
             SpecificationStore.create(context.workspace, context.project.id, attrs)

    assert revision.design_document == command
    refute File.exists?("/tmp/should-never-run")
  end

  test "rolls back the aggregate when a fault occurs after specification insertion", context do
    attrs = SpecificationFixtures.specification_attrs()

    assert {:error, :injected_failure} =
             SpecificationStore.create(
               context.workspace,
               context.project.id,
               attrs,
               fault: :after_specification
             )

    assert Repo.aggregate(ProjectSpecification, :count) == 0
    assert Repo.aggregate(SpecificationRevision, :count) == 0
  end

  test "rejects duplicate stable identities through the database constraint", context do
    attrs = SpecificationFixtures.specification_attrs()

    assert {:ok, _current} =
             SpecificationStore.create(context.workspace, context.project.id, attrs)

    assert {:error, %Ecto.Changeset{} = changeset} =
             SpecificationStore.create(context.workspace, context.project.id, attrs)

    assert "has already been taken" in errors_on(changeset).id
    assert Repo.aggregate(ProjectSpecification, :count) == 1
    assert Repo.aggregate(SpecificationRevision, :count) == 1
  end
end
