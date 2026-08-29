defmodule SddOrchestrator.RepositorySelection.AttachmentCodec do
  @moduledoc """
  The wire shape of a selection request and of a worker's answer.

  This is the slice's own codec, and it is deliberately not
  `SddOrchestrator.Delivery.ProtocolCodec`. A run command tells a worker to
  execute something inside a project it is authorized for; a folder-picker
  request asks a person to point at a folder on their own Mac. They travel on
  different topics, they mean different things, and one vocabulary growing a
  key must never widen the other.

  Encoding is closed rather than open. A request leaves as exactly four fields
  and a cancellation as exactly one, so nothing a caller happens to be holding
  can ride along. Decoding is closed for the same reason from the other side:
  a worker's answer is refused whole when it carries a key this module does not
  recognise, which is what stops a `path`, a `folder_path`, a `remote_url`, or
  a file listing from ever reaching the request table. That check is the outer
  half of the privacy boundary; `SelectionResult.new/1` is the inner half, and
  both refuse a stray key on their own.

  A worker's answer arrives from outside the control plane, so it is also
  bounded. An oversized `matches` list, folder name, or identity is refused
  instead of held, because a trusted worker never sends one and an untrusted
  sender must not be able to make the control plane carry what it sent.

  This module writes no log line. Refusing an answer is not an event worth
  naming a Mac in.
  """

  alias SddOrchestrator.RepositorySelection.SelectionRequest

  # The only keys a worker's answer may carry. Everything else is refused with
  # the whole payload, including any key that would name a location.
  @result_keys ~w(request_id outcome folder_name matches identity)

  # A worker compares against the candidates it was sent, so a longer answer
  # than any plausible request is not an answer this control plane asked for.
  @max_matches 100

  # A folder name is one path segment, and an identity is a short opaque
  # string. Both are bounded well above what a real one needs.
  @max_folder_name_bytes 255
  @max_identity_bytes 512

  @doc """
  Builds the outbound payload for one open request.

  The payload holds the request id, the identities to compare against under
  the requester's own references, whether a fresh identity is wanted, and when
  the request stops being answerable. Nothing else, because nothing else is
  the worker's business.
  """
  @spec encode_request(SelectionRequest.t()) :: {:ok, map()} | {:error, :invalid_request}
  def encode_request(%SelectionRequest{} = request) do
    with {:ok, request_id} <- encode_id(request.id),
         {:ok, candidates} <- encode_candidates(request.candidates),
         {:ok, generate} <- encode_generate(request.generate?),
         {:ok, expires_at} <- encode_expiry(request.expires_at) do
      {:ok,
       %{
         "request_id" => request_id,
         "candidates" => candidates,
         "generate" => generate,
         "expires_at" => expires_at
       }}
    end
  end

  @doc """
  Builds the outbound payload that tells a worker to close its panel.

  It names the request and nothing more. The worker already holds everything
  else it was told, and a cancellation is not the place to tell it again.
  """
  @spec encode_cancellation(SelectionRequest.t()) :: {:ok, map()} | {:error, :invalid_request}
  def encode_cancellation(%SelectionRequest{} = request) do
    case encode_id(request.id) do
      {:ok, request_id} -> {:ok, %{"request_id" => request_id}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Turns one worker's inbound payload into the attributes an answer accepts.

  The payload is refused whole when it carries any key outside the recognised
  set, or when a recognised value is larger than a real answer ever is. What
  comes back is handed to `SddOrchestrator.RepositorySelection.answer/2`, which
  decides whether the request is open and whether this attachment may close it.
  """
  @spec decode_result(map()) :: {:ok, map()} | {:error, :invalid_result}
  def decode_result(payload) when is_map(payload) do
    with :ok <- confirm_keys(payload),
         :ok <- confirm_matches(payload),
         :ok <- confirm_folder_name(payload),
         :ok <- confirm_identity(payload) do
      {:ok, payload}
    end
  end

  def decode_result(_payload), do: {:error, :invalid_result}

  @doc "The keys a worker's answer may carry."
  @spec result_keys() :: [String.t()]
  def result_keys, do: @result_keys

  defp encode_id(id) when is_binary(id) and byte_size(id) > 0, do: {:ok, id}
  defp encode_id(_id), do: {:error, :invalid_request}

  defp encode_candidates(candidates) when is_list(candidates) do
    reduced =
      Enum.reduce_while(candidates, {:ok, []}, fn candidate, {:ok, encoded} ->
        case encode_candidate(candidate) do
          {:ok, wire} -> {:cont, {:ok, [wire | encoded]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case reduced do
      {:ok, encoded} -> {:ok, Enum.reverse(encoded)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp encode_candidates(_candidates), do: {:error, :invalid_request}

  # A reference is the requester's own handle and comes straight back in the
  # answer's `matches`, so it has to survive a round trip through JSON. Only a
  # value with one obvious string form is accepted; anything else would come
  # back as something the requester could not recognise.
  defp encode_candidate(%{ref: ref, identity: identity}) when is_binary(identity) do
    case encode_ref(ref) do
      {:ok, ref} -> {:ok, %{"ref" => ref, "identity" => identity}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp encode_candidate(_candidate), do: {:error, :invalid_request}

  defp encode_ref(ref) when is_binary(ref) or is_atom(ref) or is_integer(ref),
    do: {:ok, to_string(ref)}

  defp encode_ref(_ref), do: {:error, :invalid_request}

  defp encode_generate(generate) when is_boolean(generate), do: {:ok, generate}
  defp encode_generate(_generate), do: {:error, :invalid_request}

  defp encode_expiry(%DateTime{} = expires_at), do: {:ok, DateTime.to_iso8601(expires_at)}
  defp encode_expiry(_expires_at), do: {:error, :invalid_request}

  defp confirm_keys(payload) do
    if Enum.all?(Map.keys(payload), &(&1 in @result_keys)) do
      :ok
    else
      {:error, :invalid_result}
    end
  end

  defp confirm_matches(payload) do
    case Map.get(payload, "matches") do
      matches when is_list(matches) and length(matches) > @max_matches ->
        {:error, :invalid_result}

      _within_bounds ->
        :ok
    end
  end

  defp confirm_folder_name(payload),
    do: confirm_size(Map.get(payload, "folder_name"), @max_folder_name_bytes)

  defp confirm_identity(payload),
    do: confirm_size(Map.get(payload, "identity"), @max_identity_bytes)

  defp confirm_size(value, limit) when is_binary(value) and byte_size(value) > limit,
    do: {:error, :invalid_result}

  defp confirm_size(_value, _limit), do: :ok
end
