defmodule SddOrchestrator.Portability.HostedRestore do
  @moduledoc """
  Atomic hosted adapter for one validated project backup.

  A single `Ecto.Multi` inserts the stable project identity, canonical repository
  identity, hosted storage root, minimal provenance, and current specification
  set. Repository authorization is deliberately absent, so no
  `RepositoryConnection` is created. Database constraints arbitrate concurrent
  identity, name, and repository races.

  The public restore workflow must run `RestoreConflicts` first. This adapter can
  reconcile an exact committed replay for a lost acknowledgement, but it never
  treats a different record with the same identity as a retry.
  """

  alias Ecto.Multi
  alias SddOrchestrator.Accounts.PersonalWorkspace

  alias SddOrchestrator.Portability.{
    PackageProvenance,
    PackageValidator,
    ProjectPackage,
    RestoreDecision,
    RestorePackage,
    SecurityLog
  }

  alias SddOrchestrator.Projects
  alias SddOrchestrator.Projects.Project
  alias SddOrchestrator.ProjectStorage.HostedProjectStorage
  alias SddOrchestrator.Repo
  alias SddOrchestrator.Specifications.SpecificationRestore
  alias SddOrchestrator.SpecificationStore

  @type success :: %{
          project: Project.t(),
          provenance: PackageProvenance.t(),
          specifications: list(),
          replay?: boolean()
        }

  @doc """
  Restores one already-validated package and decision into a persisted personal
  workspace.

  `idempotency_key` is required by the shared specification contribution and is
  held only for the active operation; it is not persisted as provenance.
  """
  @spec restore(PersonalWorkspace.t(), ProjectPackage.t(), RestoreDecision.t(), keyword()) ::
          {:ok, success()}
          | {:error,
             :invalid_restore
             | :not_found
             | :identity_conflict
             | :name_conflict
             | :repository_conflict
             | :specification_conflict
             | :injected_failure
             | term()}
  def restore(
        %PersonalWorkspace{} = authority,
        %ProjectPackage{} = package,
        %RestoreDecision{} = decision,
        opts
      ) do
    result =
      with %PersonalWorkspace{} <- Repo.get(PersonalWorkspace, authority.id),
           :ok <- PackageValidator.validate(package),
           {:ok, idempotency_key} <-
             SpecificationRestore.validate_idempotency_key(Keyword.get(opts, :idempotency_key)),
           {:ok, specification_values} <- RestorePackage.specification_values(package),
           :ok <- RestorePackage.decision_matches(decision, package),
           {:ok, multi} <-
             restore_multi(
               authority,
               package,
               decision,
               specification_values,
               idempotency_key,
               opts
             ) do
        commit_restore(authority, package, decision, specification_values, multi)
      else
        nil -> {:error, :not_found}
        {:error, _reason} = error -> error
        _other -> {:error, :invalid_restore}
      end

    SecurityLog.audit(result, :restore_commit)
  end

  def restore(_authority, _package, _decision, _opts) do
    SecurityLog.audit({:error, :invalid_restore}, :restore_commit)
  end

  defp restore_multi(
         authority,
         package,
         decision,
         specification_values,
         idempotency_key,
         opts
       ) do
    fault = Keyword.get(opts, :fault)
    restored_at = Keyword.get(opts, :restored_at, now())

    multi =
      Multi.new()
      |> Multi.insert(:project, project_changeset(authority, decision))
      |> maybe_fault(:after_project, fault)
      |> Multi.insert(:storage, fn %{project: project} ->
        HostedProjectStorage.create_changeset(%HostedProjectStorage{}, %{
          project_id: project.id,
          root: "hosted/" <> project.id,
          state: "ready"
        })
      end)
      |> maybe_fault(:after_storage, fault)
      |> Multi.insert(:provenance, fn %{project: project} ->
        PackageProvenance.create_changeset(%PackageProvenance{}, %{
          project_id: project.id,
          payload_schema_version: package.payload_schema_version,
          restored_at: restored_at
        })
      end)
      |> maybe_fault(:after_provenance, fault)

    SpecificationStore.prepare_restore(
      authority,
      multi,
      specification_values,
      idempotency_key: idempotency_key,
      project_operation: :project,
      fault: specification_fault(fault)
    )
  end

  defp project_changeset(authority, decision) do
    Project.restore_changeset(%Project{}, %{
      id: decision.project_id,
      name: decision.display_name,
      workspace_id: authority.id,
      storage_mode: "hosted",
      lifecycle_state: "active",
      repository_provider: decision.repository_provider,
      canonical_repository_id: decision.repository_id
    })
  end

  defp maybe_fault(multi, stage, stage) do
    Multi.run(multi, {:fault, stage}, fn _repo, _changes -> {:error, :injected_failure} end)
  end

  defp maybe_fault(multi, _stage, _fault), do: multi

  defp specification_fault(:after_specification), do: :after_specification
  defp specification_fault(_fault), do: nil

  defp commit_restore(authority, package, decision, specification_values, multi) do
    case Repo.transaction(multi) do
      {:ok, changes} ->
        {:ok,
         %{
           project: preload_project(changes.project),
           provenance: changes.provenance,
           specifications: specification_changes(changes),
           replay?: false
         }}

      {:error, _operation, _reason, _changes} = failure ->
        resolve_failure(authority, package, decision, specification_values, failure)
    end
  end

  defp specification_changes(changes) do
    changes
    |> Enum.find_value([], fn
      {{:specification_restore, _idempotency_key}, specifications} -> specifications
      _change -> nil
    end)
  end

  defp resolve_failure(
         authority,
         package,
         decision,
         specification_values,
         {:error, operation, reason, _changes}
       ) do
    case exact_replay(authority, package, decision, specification_values) do
      {:ok, replay} -> {:ok, replay}
      :not_replay -> {:error, failure_reason(operation, reason)}
    end
  end

  defp exact_replay(authority, package, decision, specification_values) do
    with %Project{} = project <- Projects.get_project(authority, decision.project_id),
         true <- project_matches?(project, decision),
         %PackageProvenance{} = provenance <- Repo.get(PackageProvenance, project.id),
         true <- provenance.payload_schema_version == package.payload_schema_version,
         {:ok, snapshot} <- SpecificationStore.current_snapshot(authority, project.id),
         true <- snapshot_matches?(snapshot.specifications, specification_values) do
      {:ok,
       %{
         project: project,
         provenance: provenance,
         specifications: snapshot.specifications,
         replay?: true
       }}
    else
      _reason -> :not_replay
    end
  end

  defp project_matches?(project, decision) do
    project.name == decision.display_name and
      project.storage_mode == "hosted" and
      project.lifecycle_state == "active" and
      project.repository_provider == decision.repository_provider and
      project.canonical_repository_id == decision.repository_id and
      is_nil(project.repository_connection) and
      not is_nil(project.hosted_storage) and
      project.hosted_storage.state == "ready" and
      project.hosted_storage.root == "hosted/" <> project.id
  end

  defp snapshot_matches?(snapshot, expected_values) do
    actual =
      snapshot
      |> Enum.map(&Map.from_struct/1)
      |> Enum.map(&Map.take(&1, [:id, :title, :revision_id, :requirements, :design, :tasks]))
      |> Enum.sort_by(& &1.id)

    expected =
      expected_values
      |> Enum.map(fn value ->
        %{
          id: value.id,
          title: value.title,
          revision_id: value.revision_id,
          requirements: value.requirements,
          design: value.design,
          tasks: value.tasks
        }
      end)
      |> Enum.sort_by(& &1.id)

    actual == expected
  end

  defp failure_reason(:project, %Ecto.Changeset{} = changeset) do
    cond do
      constraint?(changeset, "projects_workspace_repository_identity_index") ->
        :repository_conflict

      constraint?(changeset, "projects_workspace_id_name_key_index") ->
        :name_conflict

      constraint?(changeset, "projects_pkey") ->
        :identity_conflict

      true ->
        :invalid_restore
    end
  end

  defp failure_reason(_operation, :specification_conflict), do: :specification_conflict
  defp failure_reason(_operation, :injected_failure), do: :injected_failure
  defp failure_reason(_operation, reason), do: reason

  defp constraint?(changeset, name) do
    Enum.any?(changeset.errors, fn {_field, {_message, opts}} ->
      to_string(Keyword.get(opts, :constraint_name)) == name
    end)
  end

  defp preload_project(project),
    do: Repo.preload(project, [:repository_connection, :hosted_storage])

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
