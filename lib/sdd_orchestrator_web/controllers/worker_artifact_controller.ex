defmodule SddOrchestratorWeb.WorkerArtifactController do
  @moduledoc """
  The worker-initiated inbound surface for captured artifact bytes.

  This is the only place project content enters the control plane over HTTP. It
  carries no session and no cookie: the credential is the same signed worker
  token the socket verifies, presented as a bearer header, so a worker keeps its
  outbound-only posture and gains no second identity.

  The body is streamed under a hard cap rather than buffered and then measured,
  so an oversized upload is refused without the control plane ever holding it.
  Everything the request declares about the bytes — type, size, digest,
  redaction — is proved by the artifact store before anything is written.

  Every refusal that would answer "does this run, attempt, or artifact exist?"
  is the same response: an unauthorized worker, another project's run, a
  superseded attempt, and a device-authoritative project are indistinguishable
  from outside. Only refusals about the caller's own bytes are named, and only
  after the caller has already proved it may upload to this run.
  """
  use SddOrchestratorWeb, :controller

  alias SddOrchestrator.Delivery.{ArtifactStore, ArtifactUpload}
  alias SddOrchestratorWeb.WorkerSocket

  # Read granularity. Memory stays bounded by the artifact limit plus one chunk,
  # because the read stops as soon as the accumulated body passes the limit.
  @chunk_bytes 64 * 1024

  @refusal "refused"
  @failure "upload_failed"

  # A refusal about the bytes the caller itself supplied discloses nothing about
  # the project, so it is named. Anything unrecognized is a failure of this
  # transport rather than a verdict, and says nothing more than that.
  @outcomes %{
    artifact_conflict: {:conflict, "artifact_conflict"},
    artifact_too_large: {:request_entity_too_large, "artifact_too_large"},
    unsupported_content_type: {:unsupported_media_type, "unsupported_content_type"},
    digest_mismatch: {:unprocessable_entity, "digest_mismatch"},
    empty_artifact: {:unprocessable_entity, "empty_artifact"},
    invalid_artifact: {:unprocessable_entity, "invalid_request"},
    invalid_redaction: {:unprocessable_entity, "invalid_redaction"},
    invalid_request: {:unprocessable_entity, "invalid_request"},
    secret_field_rejected: {:unprocessable_entity, "secret_field_rejected"},
    secret_material_rejected: {:unprocessable_entity, "secret_material_rejected"}
  }

  @doc "Accepts one authenticated worker upload for one run attempt."
  def create(conn, params) do
    case conn |> bearer() |> WorkerSocket.verify() do
      {:ok, claims} -> receive_artifact(conn, claims, params)
      :error -> refuse(conn)
    end
  end

  # The credential is proved before a single byte is read, so an unauthenticated
  # caller can never make this endpoint hold project content.
  defp receive_artifact(conn, claims, params) do
    case read_capped(conn, ArtifactStore.max_bytes()) do
      {:ok, content, conn} -> respond(conn, ArtifactUpload.accept(claims, params, content))
      {:error, reason, conn} -> fail(conn, reason)
    end
  end

  defp respond(conn, {:ok, %{ref: ref, digest: digest, stored: true}}),
    do: accepted(conn, :created, ref, digest)

  defp respond(conn, {:ok, %{ref: ref, digest: digest, stored: false}}),
    do: accepted(conn, :ok, ref, digest)

  defp respond(conn, {:error, reason}) do
    if ArtifactUpload.undisclosed?(reason), do: refuse(conn), else: fail(conn, reason)
  end

  # The answer carries the opaque reference and the digest it addresses, and
  # nothing else. There is no URL, path, host, or credential to leak, because the
  # reference is not dereferenceable by anything but the artifact store.
  defp accepted(conn, status, ref, digest) do
    conn
    |> private_response()
    |> put_status(status)
    |> json(%{ref: ref, digest: digest})
  end

  defp refuse(conn), do: error(conn, :forbidden, @refusal)

  defp fail(conn, reason) do
    {status, message} = Map.get(@outcomes, reason, {:internal_server_error, @failure})
    error(conn, status, message)
  end

  defp error(conn, status, message) do
    conn
    |> private_response()
    |> put_status(status)
    |> json(%{error: message})
  end

  defp private_response(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("referrer-policy", "no-referrer")
  end

  # The body is accumulated chunk by chunk and abandoned the moment it passes the
  # limit, so an oversized upload costs one chunk beyond the limit rather than
  # however much the peer decided to send.
  defp read_capped(conn, limit, acc \\ "") do
    case read_body(conn, length: @chunk_bytes, read_length: @chunk_bytes) do
      {:ok, chunk, read} -> bounded(read, acc <> chunk, limit, :complete)
      {:more, chunk, read} -> bounded(read, acc <> chunk, limit, :partial)
      {:error, _reason} -> {:error, :invalid_request, conn}
    end
  end

  defp bounded(conn, body, limit, _state) when byte_size(body) > limit,
    do: {:error, :artifact_too_large, conn}

  defp bounded(conn, body, _limit, :complete), do: {:ok, body, conn}
  defp bounded(conn, body, limit, :partial), do: read_capped(conn, limit, body)

  defp bearer(conn) do
    conn
    |> get_req_header("authorization")
    |> List.first()
    |> credential()
  end

  defp credential(header) when is_binary(header) do
    with [scheme, token] <- String.split(header, " ", parts: 2),
         "bearer" <- String.downcase(scheme) do
      token
    else
      _malformed -> nil
    end
  end

  defp credential(_header), do: nil
end
