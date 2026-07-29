defmodule SddOrchestrator.Delivery.Worker.ArtifactUpload do
  @moduledoc """
  The worker's side of moving one captured artifact into its project's store.

  Where the bytes go is decided by the project's storage authority, not by
  configuration and not by a flag. A device-authoritative project writes through
  `ArtifactStore` on the device itself and makes no request at all: there is no
  hosted copy to create, so there is nothing to upload. A hosted project's
  worker posts to the control plane's upload endpoint with the same signed
  credential its socket already uses.

  The digest is computed here from the bytes actually being sent, so the worker
  declares what it hashed rather than repeating a value handed to it. The
  control plane recomputes it anyway; agreeing about the bytes is the point of
  sending it.

  Answers are normalized to typed reasons. An upload that was refused, that
  contradicts an artifact already stored, or that failed in transport are three
  different outcomes to a caller deciding whether to retry, so they are not
  flattened into one error.
  """

  alias SddOrchestrator.Accounts.{DeviceWorkspace, PersonalWorkspace}
  alias SddOrchestrator.Delivery.ArtifactStore

  @path "/worker/artifacts"

  @type capture :: %{
          required(:run_id) => String.t(),
          required(:attempt_id) => String.t(),
          required(:fence) => pos_integer(),
          required(:content) => binary(),
          required(:content_type) => String.t(),
          optional(:redacted) => boolean()
        }

  @type error ::
          :refused
          | :artifact_conflict
          | :artifact_too_large
          | :unsupported_content_type
          | :digest_mismatch
          | :empty_artifact
          | :invalid_redaction
          | :invalid_request
          | :upload_failed
          | :transport_failed
          | ArtifactStore.error()

  # The control plane's own vocabulary, mapped explicitly. A reason is never
  # turned into an atom from a response body, so a peer cannot make this node
  # mint atoms it never declared.
  @reasons %{
    "refused" => :refused,
    "artifact_conflict" => :artifact_conflict,
    "artifact_too_large" => :artifact_too_large,
    "unsupported_content_type" => :unsupported_content_type,
    "digest_mismatch" => :digest_mismatch,
    "empty_artifact" => :empty_artifact,
    "invalid_redaction" => :invalid_redaction,
    "invalid_request" => :invalid_request,
    "secret_field_rejected" => :invalid_request,
    "secret_material_rejected" => :invalid_request,
    "upload_failed" => :upload_failed
  }

  @doc "The content digest this client declares for one set of bytes."
  @spec digest(binary()) :: String.t()
  def digest(content) when is_binary(content),
    do: :sha256 |> :crypto.hash(content) |> Base.encode16(case: :lower)

  @doc """
  Puts one captured artifact where the project's authority says it belongs.

  `opts` needs `:base_url` and `:token` for a hosted project, and accepts
  `:req_options` so the request contract can be proven without a live control
  plane. A device-authoritative project needs neither and makes no request.
  """
  @spec upload(ArtifactStore.authority(), Ecto.UUID.t(), capture(), keyword()) ::
          {:ok, ArtifactStore.ref()} | {:error, error()}
  def upload(authority, project_id, capture, opts \\ [])

  # No upload, by construction rather than by a check the caller could skip:
  # this branch has no URL, no credential, and no request to make.
  def upload(%DeviceWorkspace{} = authority, project_id, capture, _opts),
    do: ArtifactStore.put(authority, project_id, attrs(capture))

  def upload(%PersonalWorkspace{}, _project_id, capture, opts), do: post(capture, opts)

  def upload(_authority, _project_id, _capture, _opts), do: {:error, :unsupported_authority}

  defp post(capture, opts) do
    attrs = attrs(capture)

    [
      method: :post,
      url: base_url(opts) <> @path,
      params: declaration(capture, attrs),
      headers: [
        {"authorization", "Bearer " <> Keyword.fetch!(opts, :token)},
        {"content-type", "application/octet-stream"},
        {"accept", "application/json"}
      ],
      body: attrs.content
    ]
    |> request(opts)
    |> answer()
  end

  # Test-supplied `Req` options are merged last so the same request contract runs
  # against a stub, exactly as the repository's other outbound adapter does.
  defp request(request_opts, opts) do
    request_opts
    |> Keyword.merge(Keyword.get(opts, :req_options, []))
    |> Req.new()
    |> Req.request()
  end

  defp answer({:ok, %{status: status, body: %{"ref" => ref}}})
       when status in [200, 201] and is_binary(ref),
       do: {:ok, ref}

  defp answer({:ok, %{status: status, body: body}}), do: {:error, refusal(status, body)}
  defp answer({:error, _reason}), do: {:error, :transport_failed}

  # A refusal is one answer for every existence question, so its status is read
  # rather than its body: the control plane deliberately says no more.
  defp refusal(403, _body), do: :refused
  defp refusal(401, _body), do: :refused

  defp refusal(_status, %{"error" => error}) when is_binary(error),
    do: Map.get(@reasons, error, :upload_failed)

  defp refusal(_status, _body), do: :upload_failed

  defp base_url(opts),
    do: opts |> Keyword.fetch!(:base_url) |> String.trim_trailing("/")

  defp attrs(capture) do
    content = Map.fetch!(capture, :content)

    %{
      content: content,
      content_type: Map.fetch!(capture, :content_type),
      digest: digest(content),
      redacted: Map.get(capture, :redacted, false)
    }
  end

  # The metadata travels as query parameters because the body is the artifact
  # itself; nothing here is project content, only the binding the control plane
  # checks the upload against.
  defp declaration(capture, attrs) do
    [
      run_id: Map.fetch!(capture, :run_id),
      attempt_id: Map.fetch!(capture, :attempt_id),
      fence: Map.fetch!(capture, :fence),
      digest: attrs.digest,
      content_type: attrs.content_type,
      redacted: attrs.redacted
    ]
  end
end
