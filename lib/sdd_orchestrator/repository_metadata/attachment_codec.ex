defmodule SddOrchestrator.RepositoryMetadata.AttachmentCodec do
  @moduledoc """
  The wire shape of a metadata request and of a worker's answer.

  This is the slice's own codec, and it is deliberately not
  `SddOrchestrator.RepositorySelection.AttachmentCodec` or
  `SddOrchestrator.Delivery.ProtocolCodec`. A folder-picker request asks a
  person to point at a folder on their own Mac; a metadata request asks a
  worker to read the repository already sitting at a chosen root. They travel
  on different topics, they mean different things, and one vocabulary growing
  a key must never widen the other.

  Encoding is closed rather than open. A request leaves as exactly six fields
  and a cancellation as exactly one, so nothing a caller happens to be holding
  can ride along. Decoding is closed for the same reason from the other side:
  a worker's answer is refused whole when it carries a key this module does
  not recognise, which is what stops a `path`, a `remote_url`, or a file
  listing from ever reaching the request table. That check is the outer half
  of the privacy boundary; `MetadataAnswer.new/1` is the inner half, and both
  refuse a stray key on their own.

  A worker's answer arrives from outside the control plane, so it is also
  bounded. An oversized identity, root, commit, or refusal reason is refused
  instead of held, because a trusted worker never sends one and an untrusted
  sender must not be able to make the control plane carry what it sent.

  This module writes no log line. Refusing an answer is not an event worth
  naming a Mac in.
  """

  alias SddOrchestrator.RepositoryMetadata.MetadataRequest

  # The only keys a worker's answer may carry. Everything else is refused with
  # the whole payload, including any key that would name a location.
  @result_keys ~w(request_id outcome repository_provider repository_id root commit reason)

  # None of these ever hold a full path, so this is a sanity bound rather than
  # a functional one, applied uniformly instead of inventing a per-field limit.
  @max_field_bytes 2048

  @doc """
  Builds the outbound payload for one open request.

  The payload holds the request id, the selection it is scoped to, the
  repository identity and root the worker is asked to confirm, and when the
  request stops being answerable. Nothing else, because nothing else is the
  worker's business.
  """
  @spec encode_request(MetadataRequest.t()) :: {:ok, map()} | {:error, :invalid_request}
  def encode_request(%MetadataRequest{} = request) do
    with {:ok, request_id} <- encode_id(request.id),
         {:ok, selection_ref} <- encode_id(request.selection_ref),
         {:ok, repository_provider} <- encode_id(request.repository_provider),
         {:ok, repository_id} <- encode_id(request.repository_id),
         {:ok, selected_root} <- encode_id(request.selected_root),
         {:ok, expires_at} <- encode_expiry(request.expires_at) do
      {:ok,
       %{
         "request_id" => request_id,
         "selection_ref" => selection_ref,
         "repository_provider" => repository_provider,
         "repository_id" => repository_id,
         "selected_root" => selected_root,
         "expires_at" => expires_at
       }}
    end
  end

  @doc """
  Builds the outbound payload that tells a worker to stop reading.

  It names the request and nothing more. The worker already holds everything
  else it was told, and a cancellation is not the place to tell it again.
  """
  @spec encode_cancellation(MetadataRequest.t()) :: {:ok, map()} | {:error, :invalid_request}
  def encode_cancellation(%MetadataRequest{} = request) do
    case encode_id(request.id) do
      {:ok, request_id} -> {:ok, %{"request_id" => request_id}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Turns one worker's inbound payload into the attributes an answer accepts.

  The payload is refused whole when it carries any key outside the recognised
  set, or when a recognised value is larger than a real answer ever is. What
  comes back is handed to `SddOrchestrator.RepositoryMetadata.answer/2`, which
  decides whether the request is open and whether this attachment may close
  it.
  """
  @spec decode_result(map()) :: {:ok, map()} | {:error, :invalid_result}
  def decode_result(payload) when is_map(payload) do
    with :ok <- confirm_keys(payload),
         :ok <- confirm_sizes(payload) do
      {:ok, payload}
    end
  end

  def decode_result(_payload), do: {:error, :invalid_result}

  @doc "The keys a worker's answer may carry."
  @spec result_keys() :: [String.t()]
  def result_keys, do: @result_keys

  defp encode_id(id) when is_binary(id) and byte_size(id) > 0, do: {:ok, id}
  defp encode_id(_id), do: {:error, :invalid_request}

  defp encode_expiry(%DateTime{} = expires_at), do: {:ok, DateTime.to_iso8601(expires_at)}
  defp encode_expiry(_expires_at), do: {:error, :invalid_request}

  defp confirm_keys(payload) do
    if Enum.all?(Map.keys(payload), &(&1 in @result_keys)) do
      :ok
    else
      {:error, :invalid_result}
    end
  end

  defp confirm_sizes(payload) do
    ~w(repository_provider repository_id root commit reason)
    |> Enum.reduce_while(:ok, fn key, :ok ->
      case confirm_size(Map.get(payload, key)) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp confirm_size(value) when is_binary(value) and byte_size(value) > @max_field_bytes,
    do: {:error, :invalid_result}

  defp confirm_size(_value), do: :ok
end
