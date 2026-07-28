defmodule SddOrchestrator.Specifications.SpecificationStore.Hosted do
  @moduledoc false

  import Ecto.Query

  alias Ecto.Multi
  alias SddOrchestrator.Accounts.PersonalWorkspace
  alias SddOrchestrator.Repo

  alias SddOrchestrator.Specifications.{
    ProjectSpecification,
    SpecificationAuthorization,
    SpecificationDocuments,
    SpecificationLimits,
    SpecificationRestore,
    SpecificationRevision,
    SpecificationSnapshot
  }

  alias SddOrchestrator.Specifications.SpecificationRestore.Entry

  @spec create(PersonalWorkspace.t(), String.t(), map(), keyword()) ::
          {:ok, SddOrchestrator.SpecificationStore.current()}
          | {:error, atom() | Ecto.Changeset.t()}
  def create(%PersonalWorkspace{} = authority, project_id, attrs, opts) when is_map(attrs) do
    with {:ok, project} <- SpecificationAuthorization.hosted_project(authority, project_id),
         :ok <- ensure_project_capacity(project.id),
         {:ok, specification_id} <- required_uuid(attrs, :id),
         {:ok, title} <- required_binary(attrs, :title),
         {:ok, documents} <- fetch_documents(attrs),
         {:ok, actor_ref} <- actor_ref(opts),
         revision_id <- revision_id(attrs) do
      create_transaction(
        project,
        specification_id,
        revision_id,
        title,
        documents,
        actor_ref,
        opts
      )
    end
  end

  def create(_authority, _project_id, _attrs, _opts), do: {:error, :invalid_specification}

  @spec get_current(PersonalWorkspace.t(), String.t(), String.t()) ::
          {:ok, SddOrchestrator.SpecificationStore.current()} | {:error, :not_found}
  def get_current(%PersonalWorkspace{} = authority, project_id, specification_id) do
    with {:ok, project} <- SpecificationAuthorization.hosted_project(authority, project_id),
         {:ok, specification_uuid} <- Ecto.UUID.cast(specification_id),
         {specification, revision} when not is_nil(specification) <-
           current_query(project.id, specification_uuid) do
      {:ok, %{specification: specification, revision: revision}}
    else
      _reason -> {:error, :not_found}
    end
  end

  @spec append_revision(
          PersonalWorkspace.t(),
          String.t(),
          String.t(),
          String.t(),
          map()
        ) ::
          {:ok, SddOrchestrator.SpecificationStore.current()}
          | {:error, atom() | Ecto.Changeset.t()}
  def append_revision(
        %PersonalWorkspace{} = authority,
        project_id,
        specification_id,
        expected_revision_id,
        attrs
      )
      when is_map(attrs) do
    with {:ok, project} <- SpecificationAuthorization.hosted_project(authority, project_id),
         {:ok, specification_uuid} <- cast_uuid(specification_id, :invalid_specification),
         {:ok, expected_revision_uuid} <- cast_uuid(expected_revision_id, :invalid_revision),
         {:ok, revision_uuid} <- optional_uuid(attrs, :revision_id),
         {:ok, documents} <- fetch_documents(attrs),
         {:ok, actor_ref} <- actor_ref_from_attrs(attrs),
         {:ok, title_attrs} <- title_attrs(attrs) do
      append_transaction(
        project.id,
        specification_uuid,
        expected_revision_uuid,
        revision_uuid,
        documents,
        actor_ref,
        title_attrs
      )
    end
  end

  def append_revision(_authority, _project_id, _specification_id, _expected_revision_id, _attrs),
    do: {:error, :invalid_specification}

  @spec current_snapshot(PersonalWorkspace.t(), String.t()) ::
          {:ok, SpecificationSnapshot.t()} | {:error, atom()}
  def current_snapshot(%PersonalWorkspace{} = authority, project_id) do
    with {:ok, project} <- SpecificationAuthorization.hosted_project(authority, project_id) do
      currents =
        Repo.all(
          from specification in ProjectSpecification,
            join: revision in SpecificationRevision,
            on: revision.id == specification.current_revision_id,
            where: specification.project_id == ^project.id and revision.project_id == ^project.id,
            order_by: [asc: specification.id],
            select: %{specification: specification, revision: revision}
        )

      SpecificationSnapshot.new(currents)
    end
  end

  def prepare_restore(%PersonalWorkspace{} = authority, %Multi{} = multi, values, opts) do
    project_operation = Keyword.get(opts, :project_operation, :project)
    fault = Keyword.get(opts, :fault)

    with %PersonalWorkspace{} <- Repo.get(PersonalWorkspace, authority.id),
         true <- is_atom(project_operation),
         {:ok, idempotency_key} <-
           SpecificationRestore.validate_idempotency_key(Keyword.get(opts, :idempotency_key)),
         {:ok, entries} <- SpecificationRestore.normalize(values) do
      add_restore_contribution(
        multi,
        authority.id,
        project_operation,
        idempotency_key,
        entries,
        fault
      )
    else
      false -> {:error, :invalid_restore}
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp add_restore_contribution(
         multi,
         workspace_id,
         project_operation,
         idempotency_key,
         entries,
         fault
       ) do
    digest = SpecificationRestore.digest(entries)

    plan = %{
      digest: digest,
      fault: fault,
      project_operation: project_operation,
      workspace_id: workspace_id
    }

    plan_name = {:specification_restore_plan, idempotency_key}
    commit_name = {:specification_restore, idempotency_key}

    case existing_restore_plan(multi) do
      nil ->
        multi =
          multi
          |> Multi.put(plan_name, plan)
          |> Multi.run(
            commit_name,
            restore_callback(workspace_id, project_operation, entries, fault)
          )

        {:ok, multi}

      {^plan_name, {:put, ^plan}} ->
        {:ok, multi}

      _other ->
        {:error, :restore_conflict}
    end
  end

  defp restore_callback(workspace_id, project_operation, entries, fault) do
    fn repo, changes ->
      case restore_project(changes, project_operation, workspace_id) do
        {:ok, project} -> restore_hosted_entries(repo, project, entries, fault)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp existing_restore_plan(multi) do
    Enum.find(Multi.to_list(multi), fn
      {{:specification_restore_plan, _idempotency_key}, _operation} -> true
      _operation -> false
    end)
  end

  defp restore_project(changes, project_operation, workspace_id) do
    case Map.fetch(changes, project_operation) do
      {:ok, %{workspace_id: ^workspace_id, storage_mode: "hosted"} = project} ->
        {:ok, project}

      _other ->
        {:error, :not_found}
    end
  end

  defp restore_hosted_entries(repo, project, entries, fault) do
    existing = current_project_entries(repo, project.id)

    cond do
      existing == [] ->
        with :ok <- ensure_restore_identities_available(repo, entries) do
          insert_restored_entries(repo, project, entries, fault)
        end

      restored_entries_match?(existing, entries) ->
        {:ok, existing}

      true ->
        {:error, :specification_conflict}
    end
  end

  defp current_project_entries(repo, project_id) do
    repo.all(
      from specification in ProjectSpecification,
        join: revision in SpecificationRevision,
        on: revision.id == specification.current_revision_id,
        where: specification.project_id == ^project_id and revision.project_id == ^project_id,
        order_by: [asc: specification.id],
        select: %{specification: specification, revision: revision}
    )
  end

  defp ensure_restore_identities_available(repo, entries) do
    specification_ids = Enum.map(entries, & &1.id)
    revision_ids = Enum.map(entries, & &1.revision_id)

    conflict? =
      repo.exists?(
        from specification in ProjectSpecification,
          where: specification.id in ^specification_ids
      ) or
        repo.exists?(
          from revision in SpecificationRevision,
            where: revision.id in ^revision_ids
        )

    if conflict?, do: {:error, :specification_conflict}, else: :ok
  end

  defp insert_restored_entries(repo, project, entries, fault) do
    entries
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {entry, index}, {:ok, restored} ->
      case insert_restored_entry(repo, project, entry) do
        {:ok, _current} when fault == :after_specification and index == 0 ->
          {:halt, {:error, :injected_failure}}

        {:ok, current} ->
          {:cont, {:ok, [current | restored]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, restored} -> {:ok, Enum.reverse(restored)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_restored_entry(repo, project, %Entry{} = entry) do
    with {:ok, specification} <-
           repo.insert(
             ProjectSpecification.create_changeset(%ProjectSpecification{}, %{
               id: entry.id,
               project_id: project.id,
               title: entry.title
             })
           ),
         {:ok, revision} <-
           repo.insert(
             SpecificationRevision.create_changeset(%SpecificationRevision{}, %{
               id: entry.revision_id,
               specification_id: entry.id,
               project_id: project.id,
               sequence: 1,
               requirements_document: entry.documents.requirements,
               design_document: entry.documents.design,
               tasks_document: entry.documents.tasks,
               content_digest: SpecificationDocuments.digest(entry.documents),
               actor_ref: nil
             })
           ),
         {:ok, current_specification} <-
           repo.update(ProjectSpecification.current_revision_changeset(specification, revision)) do
      {:ok, %{specification: current_specification, revision: revision}}
    end
  end

  defp restored_entries_match?(existing, entries) when length(existing) == length(entries) do
    Enum.zip(existing, entries)
    |> Enum.all?(fn {current, entry} ->
      SpecificationRestore.matches_current?(current, entry)
    end)
  end

  defp restored_entries_match?(_existing, _entries), do: false

  defp create_transaction(
         project,
         specification_id,
         revision_id,
         title,
         documents,
         actor_ref,
         opts
       ) do
    specification_changeset =
      ProjectSpecification.create_changeset(%ProjectSpecification{}, %{
        id: specification_id,
        project_id: project.id,
        title: title
      })

    Multi.new()
    |> Multi.insert(:specification, specification_changeset)
    |> maybe_inject_fault(opts)
    |> Multi.insert(:revision, fn %{specification: specification} ->
      SpecificationRevision.create_changeset(%SpecificationRevision{}, %{
        id: revision_id,
        specification_id: specification.id,
        project_id: project.id,
        sequence: 1,
        requirements_document: documents.requirements,
        design_document: documents.design,
        tasks_document: documents.tasks,
        content_digest: SpecificationDocuments.digest(documents),
        actor_ref: actor_ref
      })
    end)
    |> Multi.update(:current_specification, fn %{
                                                 specification: specification,
                                                 revision: revision
                                               } ->
      ProjectSpecification.current_revision_changeset(specification, revision)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{current_specification: specification, revision: revision}} ->
        {:ok, %{specification: specification, revision: revision}}

      {:error, _operation, %Ecto.Changeset{} = changeset, _changes} ->
        {:error, changeset}

      {:error, _operation, reason, _changes} ->
        {:error, reason}
    end
  end

  defp current_query(project_id, specification_id) do
    Repo.one(
      from specification in ProjectSpecification,
        join: revision in SpecificationRevision,
        on: revision.id == specification.current_revision_id,
        where:
          specification.id == ^specification_id and specification.project_id == ^project_id and
            revision.project_id == ^project_id,
        select: {specification, revision}
    ) || {nil, nil}
  end

  defp append_transaction(
         project_id,
         specification_id,
         expected_revision_id,
         revision_id,
         documents,
         actor_ref,
         title_attrs
       ) do
    digest = SpecificationDocuments.digest(documents)

    Repo.transaction(fn ->
      specification =
        Repo.one(
          from specification in ProjectSpecification,
            where:
              specification.id == ^specification_id and specification.project_id == ^project_id,
            lock: "FOR UPDATE"
        )

      if is_nil(specification), do: Repo.rollback(:not_found)

      current_revision = Repo.get!(SpecificationRevision, specification.current_revision_id)

      cond do
        specification.current_revision_id == revision_id ->
          idempotent_append(
            specification,
            current_revision,
            documents,
            digest,
            actor_ref,
            title_attrs
          )

        specification.current_revision_id != expected_revision_id ->
          Repo.rollback(:stale_revision)

        Repo.exists?(
          from revision in SpecificationRevision,
            where: revision.id == ^revision_id
        ) ->
          Repo.rollback(:revision_conflict)

        true ->
          insert_and_advance(
            specification,
            current_revision,
            revision_id,
            documents,
            digest,
            actor_ref,
            title_attrs
          )
      end
    end)
  end

  defp insert_and_advance(
         specification,
         current_revision,
         revision_id,
         documents,
         digest,
         actor_ref,
         title_attrs
       ) do
    revision =
      %SpecificationRevision{}
      |> SpecificationRevision.create_changeset(%{
        id: revision_id,
        specification_id: specification.id,
        project_id: specification.project_id,
        sequence: current_revision.sequence + 1,
        requirements_document: documents.requirements,
        design_document: documents.design,
        tasks_document: documents.tasks,
        content_digest: digest,
        actor_ref: actor_ref
      })
      |> Repo.insert()
      |> case do
        {:ok, revision} -> revision
        {:error, changeset} -> Repo.rollback(changeset)
      end

    updated_specification =
      specification
      |> ProjectSpecification.advance_changeset(revision, title_attrs)
      |> Repo.update()
      |> case do
        {:ok, updated} -> updated
        {:error, changeset} -> Repo.rollback(changeset)
      end

    %{specification: updated_specification, revision: revision}
  end

  defp idempotent_append(
         specification,
         current_revision,
         documents,
         digest,
         actor_ref,
         title_attrs
       ) do
    requested_title = Map.get(title_attrs, :title, specification.title)

    if current_revision.content_digest == digest and current_revision.actor_ref == actor_ref and
         current_revision.requirements_document == documents.requirements and
         current_revision.design_document == documents.design and
         current_revision.tasks_document == documents.tasks and
         specification.title == String.trim(requested_title) do
      %{specification: specification, revision: current_revision}
    else
      Repo.rollback(:revision_conflict)
    end
  end

  defp ensure_project_capacity(project_id) do
    count =
      Repo.aggregate(
        from(specification in ProjectSpecification,
          where: specification.project_id == ^project_id
        ),
        :count
      )

    if count < SpecificationLimits.get(:max_specifications_per_project),
      do: :ok,
      else: {:error, :specification_limit_exceeded}
  end

  defp fetch_documents(attrs) do
    attrs
    |> Map.get(:documents, Map.get(attrs, "documents"))
    |> SpecificationDocuments.normalize()
  end

  defp required_uuid(attrs, key) do
    value = Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))

    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_specification}
    end
  end

  defp required_binary(attrs, key) do
    case Map.get(attrs, key, Map.get(attrs, Atom.to_string(key))) do
      value when is_binary(value) -> {:ok, value}
      _value -> {:error, :invalid_specification}
    end
  end

  defp revision_id(attrs) do
    case Map.get(attrs, :revision_id, Map.get(attrs, "revision_id")) do
      nil ->
        Ecto.UUID.generate()

      value ->
        case Ecto.UUID.cast(value) do
          {:ok, uuid} -> uuid
          :error -> :invalid_revision_id
        end
    end
  end

  defp optional_uuid(attrs, key) do
    case Map.get(attrs, key, Map.get(attrs, Atom.to_string(key))) do
      nil -> {:ok, Ecto.UUID.generate()}
      value -> cast_uuid(value, :invalid_revision)
    end
  end

  defp cast_uuid(value, error) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, error}
    end
  end

  defp actor_ref(opts) do
    case Keyword.get(opts, :actor_ref) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _value -> {:error, :invalid_actor_ref}
    end
  end

  defp actor_ref_from_attrs(attrs) do
    case Map.get(attrs, :actor_ref, Map.get(attrs, "actor_ref")) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _value -> {:error, :invalid_actor_ref}
    end
  end

  defp title_attrs(attrs) do
    case Map.fetch(attrs, :title) do
      {:ok, title} when is_binary(title) -> {:ok, %{title: title}}
      {:ok, _title} -> {:error, :invalid_title}
      :error -> string_title_attrs(attrs)
    end
  end

  defp string_title_attrs(attrs) do
    case Map.fetch(attrs, "title") do
      {:ok, title} when is_binary(title) -> {:ok, %{title: title}}
      {:ok, _title} -> {:error, :invalid_title}
      :error -> {:ok, %{}}
    end
  end

  defp maybe_inject_fault(multi, opts) do
    case Keyword.get(opts, :fault) do
      :after_specification ->
        Multi.run(multi, :injected_fault, fn _repo, _changes ->
          {:error, :injected_failure}
        end)

      _other ->
        multi
    end
  end
end
