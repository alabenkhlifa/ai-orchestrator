defmodule SddOrchestrator.RepositoryScan.AttachmentCodec do
  @moduledoc """
  The wire shape of a scan request and of a worker's answer.

  This is the slice's own codec, and it is deliberately not
  `SddOrchestrator.RepositoryMetadata.AttachmentCodec`. A metadata request
  asks a worker to read four fields about a repository; a scan request asks it
  to run the bounded scanner over that repository and derive a proposal. They
  mean different things, they are bounded differently, and one vocabulary
  growing a key must never widen the other.

  Encoding is closed. A request leaves as exactly four fields, one of which is
  `RepositoryAssessmentCommand`'s own serialized value, itself closed to
  identity, root anchor, commit, digests, and limits. A cancellation leaves as
  exactly one field. Nothing a caller happens to be holding can ride along.

  Decoding is closed from the other side, and bounded. A worker's answer is
  refused whole when it carries a key this module does not recognise, and
  refused before it is read when its encoded size is larger than a result the
  domain would accept anyway. A scan answer is the first worker payload big
  enough for that bound to matter, and refusing it here is what turns an
  oversized frame into a named refusal instead of a wait that times out.

  This module writes no log line. Refusing an answer is not an event worth
  naming a Mac in.
  """

  alias SddOrchestrator.RepositoryAssessments.RepositoryAssessmentCommand
  alias SddOrchestrator.RepositoryAssessments.RepositoryAssessmentResult
  alias SddOrchestrator.RepositoryScan.ScanRequest

  # The only keys a worker's answer may carry. Everything else is refused with
  # the whole payload, including any key that would name a location.
  @result_keys ~w(request_id outcome findings structure stats proposal reason)

  # The domain refuses a result larger than this when it builds one, so an
  # answer that could never become a result is refused before it is decoded.
  # The headroom covers the proposal fields, which the result itself does not
  # carry.
  @max_payload_bytes RepositoryAssessmentResult.max_result_bytes() + 256 * 1024

  @doc """
  Builds the outbound payload for one open request.

  The payload holds the request id, the selection the folder is held under,
  the assessment command to run, and when the request stops being answerable.
  Nothing else, because nothing else is the worker's business.
  """
  @spec encode_request(ScanRequest.t()) :: {:ok, map()} | {:error, :invalid_request}
  def encode_request(%ScanRequest{} = request) do
    with {:ok, request_id} <- encode_id(request.id),
         {:ok, selection_ref} <- encode_id(request.selection_ref),
         {:ok, command} <- encode_command(request.command),
         {:ok, expires_at} <- encode_expiry(request.expires_at) do
      {:ok,
       %{
         "request_id" => request_id,
         "selection_ref" => selection_ref,
         "command" => command,
         "expires_at" => expires_at
       }}
    end
  end

  def encode_request(_request), do: {:error, :invalid_request}

  @doc """
  Builds the outbound payload that tells a worker to stop scanning.

  It names the request and nothing more. The worker already holds everything
  else it was told, and a cancellation is not the place to tell it again.
  """
  @spec encode_cancellation(ScanRequest.t()) :: {:ok, map()} | {:error, :invalid_request}
  def encode_cancellation(%ScanRequest{} = request) do
    case encode_id(request.id) do
      {:ok, request_id} -> {:ok, %{"request_id" => request_id}}
      {:error, reason} -> {:error, reason}
    end
  end

  def encode_cancellation(_request), do: {:error, :invalid_request}

  @doc """
  Turns one worker's inbound payload into the attributes an answer accepts.

  The payload is refused whole when it carries any key outside the recognised
  set, or when it is larger than an answer the domain could ever store. What
  comes back is handed to `SddOrchestrator.RepositoryScan.answer/2`, which
  decides whether the request is open and whether this attachment may close
  it.
  """
  @spec decode_result(map()) :: {:ok, map()} | {:error, :invalid_result}
  def decode_result(payload) when is_map(payload) do
    with :ok <- confirm_keys(payload),
         :ok <- confirm_size(payload) do
      {:ok, payload}
    end
  end

  def decode_result(_payload), do: {:error, :invalid_result}

  @doc "The keys a worker's answer may carry."
  @spec result_keys() :: [String.t()]
  def result_keys, do: @result_keys

  @doc "The largest answer this boundary will carry."
  @spec max_payload_bytes() :: pos_integer()
  def max_payload_bytes, do: @max_payload_bytes

  defp encode_id(id) when is_binary(id) and byte_size(id) > 0, do: {:ok, id}
  defp encode_id(_id), do: {:error, :invalid_request}

  defp encode_command(%RepositoryAssessmentCommand{} = command) do
    if RepositoryAssessmentCommand.valid?(command) do
      {:ok, RepositoryAssessmentCommand.to_value(command)}
    else
      {:error, :invalid_request}
    end
  end

  defp encode_command(_command), do: {:error, :invalid_request}

  defp encode_expiry(%DateTime{} = expires_at), do: {:ok, DateTime.to_iso8601(expires_at)}
  defp encode_expiry(_expires_at), do: {:error, :invalid_request}

  defp confirm_keys(payload) do
    if Enum.all?(Map.keys(payload), &(&1 in @result_keys)) do
      :ok
    else
      {:error, :invalid_result}
    end
  end

  defp confirm_size(payload) do
    case Jason.encode(payload) do
      {:ok, encoded} when byte_size(encoded) <= @max_payload_bytes -> :ok
      _oversized_or_unencodable -> {:error, :invalid_result}
    end
  end
end
