defmodule SddOrchestrator.Specifications.HostedAppendTest do
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Specifications.SpecificationRevision

  alias SddOrchestrator.{
    AccountsFixtures,
    ProjectsFixtures,
    SpecificationFixtures,
    SpecificationStore
  }

  setup do
    account = AccountsFixtures.account_fixture()
    workspace = ProjectsFixtures.workspace_fixture(account)
    project = ProjectsFixtures.registered_project(workspace)
    current = SpecificationFixtures.hosted_specification(workspace, project)
    %{workspace: workspace, project: project, current: current}
  end

  test "appends one immutable complete revision and atomically advances the head", context do
    attrs = append_attrs(title: "Updated title")

    assert {:ok, appended} =
             SpecificationStore.append_revision(
               context.workspace,
               context.project.id,
               context.current.specification.id,
               context.current.revision.id,
               attrs
             )

    assert appended.revision.id == attrs.revision_id
    assert appended.revision.sequence == 2
    assert appended.specification.current_revision_id == appended.revision.id
    assert appended.specification.title == "Updated title"

    original = Repo.get!(SpecificationRevision, context.current.revision.id)
    assert original.sequence == 1
    assert original.requirements_document == context.current.revision.requirements_document
    assert Repo.aggregate(SpecificationRevision, :count) == 2
  end

  test "rejects a stale expected head without inserting a revision", context do
    attrs = append_attrs()

    assert {:error, :stale_revision} =
             SpecificationStore.append_revision(
               context.workspace,
               context.project.id,
               context.current.specification.id,
               Ecto.UUID.generate(),
               attrs
             )

    assert Repo.aggregate(SpecificationRevision, :count) == 1
  end

  test "a committed retry returns the same revision without duplication", context do
    attrs = append_attrs()

    assert {:ok, first} =
             SpecificationStore.append_revision(
               context.workspace,
               context.project.id,
               context.current.specification.id,
               context.current.revision.id,
               attrs
             )

    assert {:ok, retried} =
             SpecificationStore.append_revision(
               context.workspace,
               context.project.id,
               context.current.specification.id,
               context.current.revision.id,
               attrs
             )

    assert retried.revision.id == first.revision.id
    assert Repo.aggregate(SpecificationRevision, :count) == 2
  end

  test "reusing a revision identity for different content is rejected", context do
    attrs = append_attrs()

    assert {:ok, _appended} =
             SpecificationStore.append_revision(
               context.workspace,
               context.project.id,
               context.current.specification.id,
               context.current.revision.id,
               attrs
             )

    conflicting = put_in(attrs.documents.design, "different")

    assert {:error, :revision_conflict} =
             SpecificationStore.append_revision(
               context.workspace,
               context.project.id,
               context.current.specification.id,
               context.current.revision.id,
               conflicting
             )

    assert Repo.aggregate(SpecificationRevision, :count) == 2
  end

  test "an invalid title rolls back the inserted revision", context do
    attrs = append_attrs(title: "   ")

    assert {:error, %Ecto.Changeset{}} =
             SpecificationStore.append_revision(
               context.workspace,
               context.project.id,
               context.current.specification.id,
               context.current.revision.id,
               attrs
             )

    assert Repo.aggregate(SpecificationRevision, :count) == 1
  end

  test "concurrent writers serialize so only one expected-head transition wins", context do
    requests = [
      append_attrs(documents: SpecificationFixtures.documents(%{design: "writer one"})),
      append_attrs(documents: SpecificationFixtures.documents(%{design: "writer two"}))
    ]

    results =
      requests
      |> Task.async_stream(
        fn attrs ->
          SpecificationStore.append_revision(
            context.workspace,
            context.project.id,
            context.current.specification.id,
            context.current.revision.id,
            attrs
          )
        end,
        max_concurrency: 2,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _current}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :stale_revision})) == 1
    assert Repo.aggregate(SpecificationRevision, :count) == 2
  end

  defp append_attrs(overrides \\ []) do
    %{
      revision_id: Ecto.UUID.generate(),
      actor_ref: "owner",
      documents:
        SpecificationFixtures.documents(%{
          tasks: "# Tasks\n\n- [x] Implement the store"
        })
    }
    |> Map.merge(Map.new(overrides))
  end
end
