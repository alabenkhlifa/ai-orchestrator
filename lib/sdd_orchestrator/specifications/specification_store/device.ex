defmodule SddOrchestrator.Specifications.SpecificationStore.Device do
  @moduledoc false

  alias SddOrchestrator.Accounts.DeviceWorkspace
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.DeviceTransaction

  alias SddOrchestrator.Specifications.{
    DeviceProjectSpecification,
    DeviceSpecificationRevision,
    SpecificationDocuments,
    SpecificationLimits,
    SpecificationRestore,
    SpecificationSnapshot
  }

  alias SddOrchestrator.Specifications.SpecificationRestore.DeviceContribution

  def create(%DeviceWorkspace{} = authority, project_id, attrs, opts) when is_map(attrs) do
    with :ok <- authorize(authority, project_id),
         :ok <- ensure_project_capacity(project_id),
         {:ok, specification_id} <- required_uuid(attrs, :id),
         {:ok, revision_id} <- optional_uuid(attrs, :revision_id),
         {:ok, title} <- required_title(attrs),
         {:ok, documents} <- fetch_documents(attrs),
         {:ok, actor_ref} <- actor_ref_from_opts(opts) do
      now = now()

      specification = %DeviceProjectSpecification{
        id: specification_id,
        project_id: project_id,
        title: title,
        current_revision_id: revision_id,
        inserted_at: now,
        updated_at: now
      }

      revision =
        device_revision(
          revision_id,
          specification_id,
          project_id,
          1,
          documents,
          actor_ref,
          now
        )

      Devices.create_specification(project_id, specification, revision)
    end
  end

  def append_revision(
        %DeviceWorkspace{} = authority,
        project_id,
        specification_id,
        expected_revision_id,
        attrs
      )
      when is_map(attrs) do
    with :ok <- authorize(authority, project_id),
         {:ok, specification_uuid} <- cast_uuid(specification_id, :invalid_specification),
         {:ok, expected_revision_uuid} <- cast_uuid(expected_revision_id, :invalid_revision),
         {:ok, revision_id} <- optional_uuid(attrs, :revision_id),
         {:ok, documents} <- fetch_documents(attrs),
         {:ok, actor_ref} <- actor_ref_from_attrs(attrs),
         {:ok, specification_attrs} <- title_attrs(attrs),
         {:ok, current} <- Devices.get_current_specification(project_id, specification_uuid) do
      retry? = current.specification.current_revision_id == revision_id

      revision =
        device_revision(
          revision_id,
          specification_uuid,
          project_id,
          if(retry?, do: current.revision.sequence, else: current.revision.sequence + 1),
          documents,
          actor_ref,
          if(retry?, do: current.revision.inserted_at, else: now())
        )

      Devices.append_specification_revision(
        project_id,
        specification_uuid,
        expected_revision_uuid,
        revision,
        specification_attrs
      )
    end
  end

  def get_current(%DeviceWorkspace{} = authority, project_id, specification_id) do
    with :ok <- authorize(authority, project_id),
         {:ok, specification_uuid} <- cast_uuid(specification_id, :not_found) do
      Devices.get_current_specification(project_id, specification_uuid)
    else
      _reason -> {:error, :not_found}
    end
  end

  def current_snapshot(%DeviceWorkspace{} = authority, project_id) do
    with :ok <- authorize(authority, project_id) do
      project_id
      |> Devices.current_specifications()
      |> SpecificationSnapshot.new()
    end
  end

  def prepare_restore(
        %DeviceWorkspace{} = authority,
        %DeviceTransaction{} = transaction,
        values,
        opts
      ) do
    with {:ok, %DeviceWorkspace{id: authority_id}} <- Devices.get_workspace(),
         true <- authority_id == authority.id,
         {:ok, idempotency_key} <-
           SpecificationRestore.validate_idempotency_key(Keyword.get(opts, :idempotency_key)),
         {:ok, entries} <- SpecificationRestore.normalize(values) do
      contribution = %DeviceContribution{
        idempotency_key: idempotency_key,
        digest: SpecificationRestore.digest(entries),
        entries: entries,
        fault: Keyword.get(opts, :fault)
      }

      DeviceTransaction.put(transaction, :specification_restore, contribution)
    else
      false -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp authorize(%DeviceWorkspace{id: authority_id}, project_id) do
    with {:ok, %DeviceWorkspace{id: ^authority_id}} <- Devices.get_workspace(),
         {:ok, %{storage_mode: "device"}} <- Devices.get_project(project_id) do
      :ok
    else
      _reason -> {:error, :not_found}
    end
  end

  defp ensure_project_capacity(project_id) do
    if Devices.specification_count(project_id) <
         SpecificationLimits.get(:max_specifications_per_project),
       do: :ok,
       else: {:error, :specification_limit_exceeded}
  end

  defp device_revision(
         id,
         specification_id,
         project_id,
         sequence,
         documents,
         actor_ref,
         inserted_at
       ) do
    %DeviceSpecificationRevision{
      id: id,
      specification_id: specification_id,
      project_id: project_id,
      sequence: sequence,
      requirements_document: documents.requirements,
      design_document: documents.design,
      tasks_document: documents.tasks,
      content_digest: SpecificationDocuments.digest(documents),
      actor_ref: actor_ref,
      inserted_at: inserted_at
    }
  end

  defp fetch_documents(attrs) do
    attrs
    |> Map.get(:documents, Map.get(attrs, "documents"))
    |> SpecificationDocuments.normalize()
  end

  defp required_uuid(attrs, key) do
    attrs
    |> Map.get(key, Map.get(attrs, Atom.to_string(key)))
    |> cast_uuid(:invalid_specification)
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

  defp required_title(attrs) do
    attrs
    |> Map.get(:title, Map.get(attrs, "title"))
    |> validate_title()
  end

  defp title_attrs(attrs) do
    case Map.get(attrs, :title, Map.get(attrs, "title")) do
      nil -> {:ok, %{}}
      title -> with {:ok, valid} <- validate_title(title), do: {:ok, %{title: valid}}
    end
  end

  defp validate_title(title) when is_binary(title) do
    title = String.trim(title)

    if title != "" and not Regex.match?(~r/\p{Cc}/u, title) and
         byte_size(title) <= SpecificationLimits.get(:max_title_bytes),
       do: {:ok, title},
       else: {:error, :invalid_title}
  end

  defp validate_title(_title), do: {:error, :invalid_title}

  defp actor_ref_from_opts(opts), do: validate_actor_ref(Keyword.get(opts, :actor_ref))

  defp actor_ref_from_attrs(attrs) do
    validate_actor_ref(Map.get(attrs, :actor_ref, Map.get(attrs, "actor_ref")))
  end

  defp validate_actor_ref(nil), do: {:ok, nil}

  defp validate_actor_ref(actor_ref) when is_binary(actor_ref) do
    if byte_size(actor_ref) <= SpecificationLimits.get(:max_actor_ref_bytes) and
         not String.contains?(actor_ref, "@"),
       do: {:ok, actor_ref},
       else: {:error, :invalid_actor_ref}
  end

  defp validate_actor_ref(_actor_ref), do: {:error, :invalid_actor_ref}

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
