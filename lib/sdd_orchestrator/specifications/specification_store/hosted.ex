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
    SpecificationRevision
  }

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

  defp actor_ref(opts) do
    case Keyword.get(opts, :actor_ref) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _value -> {:error, :invalid_actor_ref}
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
