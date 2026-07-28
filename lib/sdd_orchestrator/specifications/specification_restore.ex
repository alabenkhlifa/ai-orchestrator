defmodule SddOrchestrator.Specifications.SpecificationRestore do
  @moduledoc """
  Validates the allowlisted current specification set accepted by restoration.

  Package parsing, compatibility, decryption, and project conflict policy stay
  with the calling workflow. This module accepts only the already-decoded value
  shape and never resolves paths or executes document text.
  """

  alias SddOrchestrator.Specifications.{SpecificationDocuments, SpecificationLimits}
  alias SddOrchestrator.Specifications.SpecificationSnapshot

  @keys [:id, :title, :revision_id, :requirements, :design, :tasks]
  @idempotency_key_max_bytes 255

  defmodule Entry do
    @moduledoc false

    @enforce_keys [:id, :title, :revision_id, :documents]
    defstruct [:id, :title, :revision_id, :documents]

    @type t :: %__MODULE__{
            id: Ecto.UUID.t(),
            title: String.t(),
            revision_id: Ecto.UUID.t(),
            documents: SpecificationDocuments.t()
          }
  end

  defmodule DeviceContribution do
    @moduledoc false

    alias SddOrchestrator.Specifications.SpecificationRestore.Entry

    @enforce_keys [:idempotency_key, :digest, :entries]
    defstruct [:idempotency_key, :digest, :entries, :fault]

    @type t :: %__MODULE__{
            idempotency_key: String.t(),
            digest: String.t(),
            entries: [Entry.t()],
            fault: atom() | nil
          }
  end

  @spec normalize([map()]) :: {:ok, [Entry.t()]} | {:error, atom()}
  def normalize(values) when is_list(values) do
    with :ok <- validate_count(values),
         {:ok, entries} <- normalize_entries(values),
         :ok <- validate_unique_identities(entries),
         :ok <- validate_snapshot_size(entries) do
      {:ok, Enum.sort_by(entries, & &1.id)}
    end
  end

  def normalize(_values), do: {:error, :invalid_restore}

  @spec validate_idempotency_key(term()) :: {:ok, String.t()} | {:error, :invalid_idempotency_key}
  def validate_idempotency_key(value) when is_binary(value) do
    value = String.trim(value)

    if value != "" and byte_size(value) <= @idempotency_key_max_bytes and
         not Regex.match?(~r/\p{Cc}/u, value),
       do: {:ok, value},
       else: {:error, :invalid_idempotency_key}
  end

  def validate_idempotency_key(_value), do: {:error, :invalid_idempotency_key}

  @spec digest([Entry.t()]) :: String.t()
  def digest(entries) do
    entries
    |> Enum.flat_map(fn entry ->
      [
        entry.id,
        entry.title,
        entry.revision_id,
        entry.documents.requirements,
        entry.documents.design,
        entry.documents.tasks
      ]
    end)
    |> Enum.map_join(fn value -> "#{byte_size(value)}:#{value}" end)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @spec matches_current?(SddOrchestrator.SpecificationStore.current(), Entry.t()) :: boolean()
  def matches_current?(
        %{specification: specification, revision: revision},
        %Entry{} = entry
      ) do
    %{
      specification_id: specification.id,
      title: specification.title,
      current_revision_id: specification.current_revision_id,
      revision_id: revision.id,
      revision_specification_id: revision.specification_id,
      sequence: revision.sequence,
      requirements: revision.requirements_document,
      design: revision.design_document,
      tasks: revision.tasks_document,
      digest: revision.content_digest,
      actor_ref: revision.actor_ref
    } ==
      %{
        specification_id: entry.id,
        title: entry.title,
        current_revision_id: entry.revision_id,
        revision_id: entry.revision_id,
        revision_specification_id: entry.id,
        sequence: 1,
        requirements: entry.documents.requirements,
        design: entry.documents.design,
        tasks: entry.documents.tasks,
        digest: SpecificationDocuments.digest(entry.documents),
        actor_ref: nil
      }
  end

  defp validate_count(values) do
    if length(values) <= SpecificationLimits.get(:max_specifications_per_project),
      do: :ok,
      else: {:error, :specification_limit_exceeded}
  end

  defp normalize_entries(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, entries} ->
      case normalize_entry(value) do
        {:ok, entry} -> {:cont, {:ok, [entry | entries]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp normalize_entry(%SpecificationSnapshot.Entry{} = value) do
    value
    |> Map.from_struct()
    |> normalize_entry()
  end

  defp normalize_entry(value) when is_map(value) do
    with :ok <- validate_keys(value),
         {:ok, id} <- cast_uuid(fetch(value, :id)),
         {:ok, revision_id} <- cast_uuid(fetch(value, :revision_id)),
         {:ok, title} <- validate_title(fetch(value, :title)),
         {:ok, documents} <-
           SpecificationDocuments.normalize(%{
             requirements: fetch(value, :requirements),
             design: fetch(value, :design),
             tasks: fetch(value, :tasks)
           }) do
      {:ok, %Entry{id: id, title: title, revision_id: revision_id, documents: documents}}
    else
      _reason -> {:error, :invalid_restore}
    end
  end

  defp normalize_entry(_value), do: {:error, :invalid_restore}

  defp validate_keys(value) do
    normalized_keys = Enum.map(Map.keys(value), &normalize_key/1)

    if Enum.sort(normalized_keys) == Enum.sort(@keys) and
         length(Enum.uniq(normalized_keys)) == length(@keys),
       do: :ok,
       else: {:error, :invalid_restore}
  end

  defp normalize_key(key) when key in @keys, do: key

  defp normalize_key(key) when is_binary(key) do
    Enum.find(@keys, fn allowed -> Atom.to_string(allowed) == key end)
  end

  defp normalize_key(_key), do: nil

  defp fetch(value, key), do: Map.get(value, key, Map.get(value, Atom.to_string(key)))

  defp cast_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_restore}
    end
  end

  defp validate_title(title) when is_binary(title) do
    title = String.trim(title)

    if title != "" and not Regex.match?(~r/\p{Cc}/u, title) and
         byte_size(title) <= SpecificationLimits.get(:max_title_bytes),
       do: {:ok, title},
       else: {:error, :invalid_restore}
  end

  defp validate_title(_title), do: {:error, :invalid_restore}

  defp validate_unique_identities(entries) do
    specification_ids = Enum.map(entries, & &1.id)
    revision_ids = Enum.map(entries, & &1.revision_id)

    if Enum.uniq(specification_ids) == specification_ids and
         Enum.uniq(revision_ids) == revision_ids,
       do: :ok,
       else: {:error, :specification_conflict}
  end

  defp validate_snapshot_size(entries) do
    total =
      Enum.reduce(entries, 0, fn entry, acc ->
        acc +
          byte_size(entry.id) +
          byte_size(entry.title) +
          byte_size(entry.revision_id) +
          SpecificationDocuments.total_bytes(entry.documents)
      end)

    if total <= SpecificationLimits.get(:max_snapshot_bytes),
      do: :ok,
      else: {:error, :snapshot_too_large}
  end
end
