defmodule SddOrchestrator.Delivery.ArtifactStore.Device do
  @moduledoc """
  The worker-owned adapter for a device-authoritative project's artifacts.

  Nothing this adapter writes reaches the hosted database. Records go through
  the same generic device-delivery seam every other device-authoritative record
  uses, keyed by the digest that already addresses the content, so the device
  store needs no artifact-specific operation of its own.

  The device store's file is not encrypted, so the bytes are sealed with
  `SddOrchestrator.Vault` before they are written and opened again on read —
  the same treatment a device-local restore upload gets.

  Removal replaces the record with a tombstone rather than deleting a key,
  because the delivery seam applies puts and nothing else. The tombstone carries
  no content, no type, and no size: what it holds is the fact that this key is
  no longer an artifact, and every read treats it as absent.
  """
  @behaviour SddOrchestrator.Delivery.ArtifactStore

  alias SddOrchestrator.Delivery.ArtifactStore
  alias SddOrchestrator.Delivery.ArtifactStore.Artifact
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Vault

  @tombstone %{"deleted" => true}

  @impl true
  def put(_authority, project_id, attrs) do
    case record(project_id, attrs.digest) do
      {:ok, existing} -> reuse(existing, attrs)
      {:error, :not_found} -> seal_and_write(project_id, attrs)
    end
  end

  @impl true
  def fetch(_authority, project_id, ref) do
    with {:ok, digest} <- ArtifactStore.digest_from_ref(ref),
         {:ok, value} <- record(project_id, digest),
         {:ok, content} <- Vault.decrypt(value["content"]) do
      {:ok, to_artifact(value, content)}
    else
      _absent -> {:error, :not_found}
    end
  end

  @impl true
  def stat(_authority, project_id, ref) do
    with {:ok, digest} <- ArtifactStore.digest_from_ref(ref),
         {:ok, value} <- record(project_id, digest) do
      {:ok, to_artifact(value, nil)}
    else
      _absent -> {:error, :not_found}
    end
  end

  @impl true
  def delete(_authority, project_id, ref) do
    with {:ok, digest} <- ArtifactStore.digest_from_ref(ref),
         {:ok, _value} <- record(project_id, digest),
         :ok <- tombstone(project_id, [digest]) do
      :ok
    else
      _absent -> :ok
    end
  end

  @impl true
  def delete_project(_authority, project_id) do
    digests = project_id |> records() |> Enum.map(& &1["digest"])

    case tombstone(project_id, digests) do
      :ok -> {:ok, length(digests)}
      {:error, _reason} -> {:ok, 0}
    end
  end

  @impl true
  def list_refs(_authority, project_id) do
    project_id
    |> records()
    |> Enum.map(&ArtifactStore.ref_for(&1["digest"]))
    |> Enum.sort()
  end

  # Content-addressed bytes cannot carry two contradictory descriptions: the
  # same digest presented as a different type, or with a different redaction
  # claim, is a conflict rather than a second copy.
  defp reuse(existing, attrs) do
    if existing["content_type"] == attrs.content_type and existing["redacted"] == attrs.redacted do
      {:ok, ArtifactStore.ref_for(attrs.digest)}
    else
      {:error, :artifact_conflict}
    end
  end

  defp seal_and_write(project_id, attrs) do
    with {:ok, sealed} <- Vault.encrypt(attrs.content),
         {:ok, _applied} <- commit(project_id, [{attrs.digest, value(attrs, sealed)}]) do
      {:ok, ArtifactStore.ref_for(attrs.digest)}
    else
      {:error, reason} -> {:error, reason}
      _unsealed -> {:error, :artifact_rejected}
    end
  end

  # An artifact carries no `state_version`, which the device store reads as "no
  # stored version". Every write therefore expects `nil` and a repeat of the
  # same immutable record replaces it with itself rather than being refused.
  defp value(attrs, sealed) do
    %{
      "digest" => attrs.digest,
      "content_type" => attrs.content_type,
      "byte_size" => attrs.byte_size,
      "redacted" => attrs.redacted,
      "content" => sealed
    }
  end

  defp tombstone(_project_id, []), do: :ok

  defp tombstone(project_id, digests) do
    case commit(project_id, Enum.map(digests, &{&1, @tombstone})) do
      {:ok, _applied} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp commit(project_id, writes) do
    Devices.commit_delivery(
      project_id,
      Enum.map(writes, fn {digest, value} -> {:put, :artifact, digest, value, nil} end)
    )
  end

  defp record(project_id, digest) do
    case Devices.get_delivery(project_id, :artifact, digest) do
      {:ok, value} -> present(value)
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  defp records(project_id) do
    project_id
    |> Devices.list_delivery(:artifact)
    |> Enum.flat_map(fn value ->
      case present(value) do
        {:ok, present} -> [present]
        {:error, :not_found} -> []
      end
    end)
  end

  # A tombstone, or anything else the store holds under this key that is not a
  # complete artifact, reads exactly like a record that was never written.
  defp present(%{"digest" => digest, "content_type" => type, "content" => content} = value)
       when is_binary(digest) and is_binary(type) and is_binary(content),
       do: {:ok, value}

  defp present(_value), do: {:error, :not_found}

  defp to_artifact(value, content) do
    %Artifact{
      ref: ArtifactStore.ref_for(value["digest"]),
      digest: value["digest"],
      content_type: value["content_type"],
      byte_size: value["byte_size"],
      redacted: value["redacted"],
      content: content
    }
  end
end
