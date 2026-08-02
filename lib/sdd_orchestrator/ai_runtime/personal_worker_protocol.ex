defmodule SddOrchestrator.AIRuntime.PersonalWorkerProtocol do
  @moduledoc """
  Versioned vocabulary for the personal-worker AI RPC transport.

  This module owns the protocol version, the AI capability allowlist, the
  negotiation rules, the strict request and response envelope contracts, and
  the payload limits of the account-level personal AI transport. It performs
  no transport, dispatch, or persistence; the personal AI worker channel and
  the control-plane RPC boundary consume these values.

  The capability allowlist is limited to connection, catalog, quota, and
  observation operations on purpose: this transport must never grow into a
  second project-run gateway. The Slice 07 gateway's inbound message names are
  therefore owned here as an explicit denylist the channel refuses by name.

  Envelopes carry an exact field set. Unknown top-level fields are refused,
  which is what keeps credentials, provider identity, raw provider errors, and
  project content off this transport: there is simply no field they could
  travel in. Limits are measured against the encoded JSON form — a JSON
  object's byte size does not depend on key order, so plain encoding measures
  the canonical size deterministically.
  """

  @protocol_version "personal-ai/1"
  @supported_versions ["personal-ai/1"]

  @capabilities ~w(catalog/1 connection/1 observation/1 quota/1)

  # The Slice 07 run gateway's inbound message names. The personal AI channel
  # refuses these by name with a distinct typed reason.
  @project_run_commands ~w(acknowledge event heartbeat reconcile)

  @request_keys ~w(account_id capability device_workspace_id idempotency_key params request_id)
  @response_keys ~w(account_id request_id result)

  # The fields that make two requests "the same content" for idempotency:
  # everything except the per-attempt request identifier and the key itself.
  @signature_keys ~w(account_id capability device_workspace_id params)

  @default_limits [
    max_envelope_bytes: 64 * 1_024,
    max_idempotency_key_bytes: 128,
    max_capabilities: 16,
    max_completed_responses: 128
  ]

  @spec version() :: String.t()
  def version, do: @protocol_version

  @spec supported_versions() :: [String.t()]
  def supported_versions, do: @supported_versions

  @spec capabilities() :: [String.t()]
  def capabilities, do: @capabilities

  @spec project_run_commands() :: [String.t()]
  def project_run_commands, do: @project_run_commands

  @doc """
  One configured limit of this transport.

  Deployments may tighten limits through `:personal_ai_protocol_limits`
  without changing the protocol contract. The delivery protocol's limits are
  a different contract and are deliberately not shared.
  """
  @spec limit(atom()) :: pos_integer()
  def limit(name) do
    :sdd_orchestrator
    |> Application.get_env(:personal_ai_protocol_limits, [])
    |> Keyword.get(name, Keyword.fetch!(@default_limits, name))
  end

  @doc """
  Resolves the AI capability contract for one worker announcement.

  The granted set is the intersection of what the worker announced and what
  this control plane supports, so a worker can never widen its own contract.
  An unknown protocol version or an empty intersection fails closed before
  the worker is addressable.
  """
  @spec negotiate(map()) ::
          {:ok, %{protocol_version: String.t(), capabilities: [String.t()]}} | {:error, atom()}
  def negotiate(%{"protocol_version" => version, "capabilities" => announced})
      when is_list(announced) do
    with :ok <- validate_version(version),
         :ok <- validate_capability_count(announced),
         {:ok, granted} <- grant_capabilities(announced) do
      {:ok, %{protocol_version: version, capabilities: granted}}
    end
  end

  def negotiate(_announcement), do: {:error, :invalid_announcement}

  @doc """
  Validates one request envelope against the strict field allowlist and the
  connection's negotiated capabilities.
  """
  @spec validate_request(map(), [String.t()]) :: :ok | {:error, atom()}
  def validate_request(envelope, negotiated_capabilities) when is_map(envelope) do
    with :ok <- validate_keys(envelope, @request_keys),
         :ok <- validate_uuid(envelope["request_id"]),
         :ok <- validate_uuid(envelope["account_id"]),
         :ok <- validate_uuid(envelope["device_workspace_id"]),
         :ok <- validate_idempotency_key(envelope["idempotency_key"]),
         :ok <- validate_map(envelope["params"], :invalid_params),
         :ok <- validate_capability(envelope["capability"], negotiated_capabilities) do
      validate_encoded_size(envelope)
    end
  end

  def validate_request(_envelope, _negotiated_capabilities), do: {:error, :invalid_request}

  @doc """
  Validates one response envelope. The response names only the request it
  answers, the account scope it answers for, and a bounded result map.
  """
  @spec validate_response(map()) :: :ok | {:error, atom()}
  def validate_response(envelope) when is_map(envelope) do
    with :ok <- validate_keys(envelope, @response_keys),
         :ok <- validate_uuid(envelope["request_id"]),
         :ok <- validate_uuid(envelope["account_id"]),
         :ok <- validate_map(envelope["result"], :invalid_result) do
      validate_encoded_size(envelope)
    end
  end

  def validate_response(_envelope), do: {:error, :invalid_response}

  @doc """
  The content identity of one request for idempotency comparison. Two requests
  with the same idempotency key must share this signature to be the same
  request; a differing signature is a conflicting reuse of the key.
  """
  @spec request_signature(map()) :: map()
  def request_signature(envelope) when is_map(envelope), do: Map.take(envelope, @signature_keys)

  defp validate_version(version) do
    if version in @supported_versions, do: :ok, else: {:error, :unsupported_protocol_version}
  end

  defp validate_capability_count(announced) do
    if length(announced) <= limit(:max_capabilities),
      do: :ok,
      else: {:error, :too_many_capabilities}
  end

  defp grant_capabilities(announced) do
    case announced |> Enum.filter(&(&1 in @capabilities)) |> Enum.uniq() |> Enum.sort() do
      [] -> {:error, :no_shared_capability}
      granted -> {:ok, granted}
    end
  end

  defp validate_keys(envelope, expected) do
    actual = envelope |> Map.keys() |> Enum.sort()

    cond do
      actual == expected -> :ok
      Enum.any?(expected, &(&1 not in actual)) -> {:error, :missing_field}
      true -> {:error, :unknown_field}
    end
  end

  defp validate_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, _uuid} -> :ok
      :error -> {:error, :invalid_identity}
    end
  end

  defp validate_uuid(_value), do: {:error, :invalid_identity}

  defp validate_idempotency_key(value) do
    if is_binary(value) and byte_size(value) > 0 and
         byte_size(value) <= limit(:max_idempotency_key_bytes),
       do: :ok,
       else: {:error, :invalid_idempotency_key}
  end

  defp validate_map(value, _reason) when is_map(value) and not is_struct(value), do: :ok
  defp validate_map(_value, reason), do: {:error, reason}

  defp validate_capability(capability, negotiated) when is_binary(capability) do
    if capability in negotiated, do: :ok, else: {:error, :unsupported_capability}
  end

  defp validate_capability(_capability, _negotiated), do: {:error, :unsupported_capability}

  defp validate_encoded_size(envelope) do
    case Jason.encode(envelope) do
      {:ok, encoded} ->
        if byte_size(encoded) <= limit(:max_envelope_bytes),
          do: :ok,
          else: {:error, :payload_too_large}

      {:error, _reason} ->
        {:error, :invalid_params}
    end
  end
end
