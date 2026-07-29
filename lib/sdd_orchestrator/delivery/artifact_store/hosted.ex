defmodule SddOrchestrator.Delivery.ArtifactStore.Hosted do
  @moduledoc """
  The PostgreSQL adapter for a hosted project's private artifacts.

  Bytes go through `SddOrchestrator.Encrypted.Binary`, so what the database,
  its backups, and its logs hold is ciphertext. Every query is scoped to one
  project, and a reference belonging to another project is answered exactly as
  one that was never stored.
  """
  @behaviour SddOrchestrator.Delivery.ArtifactStore

  import Ecto.Query

  alias SddOrchestrator.Delivery.ArtifactStore
  alias SddOrchestrator.Delivery.ArtifactStore.Artifact
  alias SddOrchestrator.Delivery.EvidenceArtifact
  alias SddOrchestrator.Repo

  @impl true
  def put(_authority, project_id, attrs) do
    case stored(project_id, attrs.digest) do
      nil -> insert(project_id, attrs)
      %EvidenceArtifact{} = existing -> reuse(existing, attrs)
    end
  rescue
    Ecto.Query.CastError -> {:error, :unsupported_authority}
  end

  @impl true
  def fetch(_authority, project_id, ref) do
    with {:ok, digest} <- ArtifactStore.digest_from_ref(ref),
         %EvidenceArtifact{} = artifact <- stored(project_id, digest) do
      {:ok, to_artifact(artifact, artifact.content)}
    else
      _absent -> {:error, :not_found}
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_found}
  end

  @impl true
  def stat(_authority, project_id, ref) do
    with {:ok, digest} <- ArtifactStore.digest_from_ref(ref),
         %{} = metadata <- stored_metadata(project_id, digest) do
      {:ok, to_artifact(metadata, nil)}
    else
      _absent -> {:error, :not_found}
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_found}
  end

  @impl true
  def delete(_authority, project_id, ref) do
    case ArtifactStore.digest_from_ref(ref) do
      {:ok, digest} ->
        EvidenceArtifact
        |> where([a], a.project_id == ^project_id and a.digest == ^digest)
        |> Repo.delete_all()

        :ok

      :error ->
        :ok
    end
  rescue
    Ecto.Query.CastError -> :ok
  end

  @impl true
  def delete_project(_authority, project_id) do
    {count, _returned} =
      EvidenceArtifact
      |> where([a], a.project_id == ^project_id)
      |> Repo.delete_all()

    {:ok, count}
  rescue
    Ecto.Query.CastError -> {:ok, 0}
  end

  @impl true
  def list_refs(_authority, project_id) do
    EvidenceArtifact
    |> where([a], a.project_id == ^project_id)
    |> select([a], a.digest)
    |> Repo.all()
    |> Enum.map(&ArtifactStore.ref_for/1)
    |> Enum.sort()
  rescue
    Ecto.Query.CastError -> []
  end

  defp insert(project_id, attrs) do
    %EvidenceArtifact{}
    |> EvidenceArtifact.store_changeset(Map.put(attrs, :project_id, project_id))
    |> Repo.insert()
    |> case do
      {:ok, artifact} -> {:ok, ArtifactStore.ref_for(artifact.digest)}
      {:error, changeset} -> rejected(project_id, attrs, changeset)
    end
  end

  # The unique index is the last word on "the same bytes are one artifact", so a
  # write that loses the race reads what won and answers as a repeat would.
  defp rejected(project_id, attrs, changeset) do
    with true <- Keyword.has_key?(changeset.errors, :project_id),
         %EvidenceArtifact{} = existing <- stored(project_id, attrs.digest) do
      reuse(existing, attrs)
    else
      _unrelated -> {:error, :artifact_rejected}
    end
  end

  # Content-addressed bytes cannot carry two contradictory descriptions: the
  # same digest presented as a different type, or with a different redaction
  # claim, is a conflict rather than a second copy.
  defp reuse(%EvidenceArtifact{} = existing, attrs) do
    if existing.content_type == attrs.content_type and existing.redacted == attrs.redacted do
      {:ok, ArtifactStore.ref_for(existing.digest)}
    else
      {:error, :artifact_conflict}
    end
  end

  defp stored(project_id, digest) do
    EvidenceArtifact
    |> where([a], a.project_id == ^project_id and a.digest == ^digest)
    |> Repo.one()
  end

  # `stat` promises not to load the bytes, so it selects the columns it reports
  # rather than the row and then discarding the largest column in memory.
  defp stored_metadata(project_id, digest) do
    EvidenceArtifact
    |> where([a], a.project_id == ^project_id and a.digest == ^digest)
    |> select([a], %{
      digest: a.digest,
      content_type: a.content_type,
      byte_size: a.byte_size,
      redacted: a.redacted
    })
    |> Repo.one()
  end

  defp to_artifact(record, content) do
    %Artifact{
      ref: ArtifactStore.ref_for(record.digest),
      digest: record.digest,
      content_type: record.content_type,
      byte_size: record.byte_size,
      redacted: record.redacted,
      content: content
    }
  end
end
