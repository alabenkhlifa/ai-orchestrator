defmodule SddOrchestrator.Delivery.ProtocolCodec do
  @moduledoc """
  Deterministic encoding and strict decoding of worker protocol envelopes.

  Five envelope types cross the worker channel: a `command` the control plane
  dispatches, an `acknowledgement` and `heartbeat` the worker returns, a
  normalized `event`, and a `reconciliation_snapshot` used after reconnect or
  restart.

  Every envelope declares its protocol version and an exact field set. Unknown
  versions, unknown or missing fields, oversized payloads, and raw credential
  fields are rejected before any state can change. Event payload semantics stay
  with the ingestion tasks that own them; this codec validates envelope
  identity, ordering fields, structure, and limits.

  `worker_id` identifies the opaque execution target, while the manifest's
  `worker_ref` and `agent_ref` hold configured provider references.
  """

  alias SddOrchestrator.Delivery.{
    CanonicalJson,
    ExecutionManifest,
    ProtocolLimits,
    SecretBoundary,
    WorkerProtocol
  }

  @command_keys ~w(
    attempt_number command_id expected_state_version feature_id fence_token issued_at
    manifest_digest operation payload project_id protocol_version run_id type
  )
  @event_keys ~w(
    attempt_number command_id event_id event_type fence_token occurred_at payload
    protocol_version run_id sequence source type
  )
  @acknowledgement_keys ~w(
    acknowledged_at attempt_number command_id fence_token protocol_version reason run_id
    status type
  )
  @heartbeat_keys ~w(
    attempt_number fence_token last_sequence observed_at protocol_version run_id state type
    worker_id
  )
  @snapshot_keys ~w(attempts observed_at protocol_version type worker_id)
  @snapshot_attempt_keys ~w(
    attempt_number branch command_id fence_token last_sequence run_id state
  )
  @digest_pattern ~r/\A[0-9a-f]{64}\z/

  @spec encode(map()) :: {:ok, binary()} | {:error, atom()}
  def encode(envelope) when is_map(envelope) do
    with :ok <- validate(envelope),
         {:ok, encoded} <- CanonicalJson.encode(envelope),
         :ok <- validate_encoded_size(encoded) do
      {:ok, encoded}
    end
  end

  def encode(_envelope), do: {:error, :invalid_envelope}

  @spec decode(binary()) :: {:ok, map()} | {:error, atom()}
  def decode(encoded) when is_binary(encoded) do
    with :ok <- validate_encoded_size(encoded),
         {:ok, decoded} <- CanonicalJson.decode(encoded),
         true <- is_map(decoded),
         :ok <- validate(decoded) do
      {:ok, decoded}
    else
      false -> {:error, :invalid_envelope}
      {:error, _reason} = error -> error
    end
  end

  def decode(_encoded), do: {:error, :invalid_envelope}

  @spec validate(map()) :: :ok | {:error, atom()}
  def validate(%{"type" => type, "protocol_version" => version} = envelope) do
    with :ok <- validate_version(version),
         :ok <- validate_type(type),
         :ok <- validate_keys(type, envelope),
         :ok <- SecretBoundary.validate(envelope) do
      validate_envelope(type, envelope)
    end
  end

  def validate(_envelope), do: {:error, :invalid_envelope}

  @doc """
  Returns the manifest carried by one validated command envelope.
  """
  @spec manifest(map()) :: {:ok, ExecutionManifest.t()} | {:error, atom()}
  def manifest(%{"type" => "command", "payload" => %{"manifest" => manifest}}),
    do: ExecutionManifest.from_map(manifest)

  def manifest(_envelope), do: {:error, :manifest_absent}

  defp validate_version(version) do
    if WorkerProtocol.supported_version?(version),
      do: :ok,
      else: {:error, :unsupported_protocol_version}
  end

  defp validate_type(type) do
    if type in WorkerProtocol.envelope_types(),
      do: :ok,
      else: {:error, :unsupported_envelope_type}
  end

  defp validate_keys(type, envelope) do
    expected = expected_keys(type)
    actual = envelope |> Map.keys() |> Enum.sort()

    cond do
      actual == Enum.sort(expected) -> :ok
      Enum.any?(expected, &(&1 not in actual)) -> {:error, :missing_field}
      true -> {:error, :unknown_field}
    end
  end

  defp expected_keys("command"), do: @command_keys
  defp expected_keys("event"), do: @event_keys
  defp expected_keys("acknowledgement"), do: @acknowledgement_keys
  defp expected_keys("heartbeat"), do: @heartbeat_keys
  defp expected_keys("reconciliation_snapshot"), do: @snapshot_keys

  defp validate_envelope("command", envelope) do
    with :ok <- validate_ids(envelope, ~w(command_id project_id feature_id run_id)),
         :ok <- validate_positive(envelope, ~w(attempt_number fence_token)),
         :ok <- validate_non_negative(envelope, ~w(expected_state_version)),
         :ok <- validate_timestamp(envelope["issued_at"]),
         :ok <- validate_enum(envelope["operation"], WorkerProtocol.command_operations()),
         :ok <- validate_digest(envelope["manifest_digest"]),
         :ok <- validate_payload_size(envelope["payload"]) do
      validate_command_payload(envelope)
    end
  end

  defp validate_envelope("event", envelope) do
    with :ok <- validate_ids(envelope, ~w(event_id run_id command_id)),
         :ok <- validate_positive(envelope, ~w(attempt_number fence_token sequence)),
         :ok <- validate_timestamp(envelope["occurred_at"]),
         :ok <- validate_enum(envelope["event_type"], WorkerProtocol.event_types()),
         :ok <- validate_enum(envelope["source"], WorkerProtocol.event_sources()) do
      validate_payload_size(envelope["payload"])
    end
  end

  defp validate_envelope("acknowledgement", envelope) do
    with :ok <- validate_ids(envelope, ~w(command_id run_id)),
         :ok <- validate_positive(envelope, ~w(attempt_number fence_token)),
         :ok <- validate_timestamp(envelope["acknowledged_at"]),
         :ok <- validate_enum(envelope["status"], WorkerProtocol.acknowledgement_statuses()) do
      validate_acknowledgement_reason(envelope["status"], envelope["reason"])
    end
  end

  defp validate_envelope("heartbeat", envelope) do
    with :ok <- validate_ids(envelope, ~w(run_id worker_id)),
         :ok <- validate_positive(envelope, ~w(attempt_number fence_token)),
         :ok <- validate_non_negative(envelope, ~w(last_sequence)),
         :ok <- validate_timestamp(envelope["observed_at"]) do
      validate_enum(envelope["state"], WorkerProtocol.heartbeat_states())
    end
  end

  defp validate_envelope("reconciliation_snapshot", envelope) do
    with :ok <- validate_ids(envelope, ~w(worker_id)),
         :ok <- validate_timestamp(envelope["observed_at"]) do
      validate_snapshot_attempts(envelope["attempts"])
    end
  end

  defp validate_ids(envelope, keys) do
    if Enum.all?(keys, &WorkerProtocol.valid_id?(envelope[&1])),
      do: :ok,
      else: {:error, :invalid_identity}
  end

  defp validate_positive(envelope, keys) do
    if Enum.all?(keys, &positive_integer?(envelope[&1])),
      do: :ok,
      else: {:error, :invalid_ordering_value}
  end

  defp validate_non_negative(envelope, keys) do
    if Enum.all?(keys, &non_negative_integer?(envelope[&1])),
      do: :ok,
      else: {:error, :invalid_ordering_value}
  end

  defp positive_integer?(value), do: is_integer(value) and value > 0
  defp non_negative_integer?(value), do: is_integer(value) and value >= 0

  defp validate_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, _datetime, 0} -> validate_utc_suffix(value)
      _other -> {:error, :invalid_timestamp}
    end
  end

  defp validate_timestamp(_value), do: {:error, :invalid_timestamp}

  defp validate_utc_suffix(value) do
    if String.ends_with?(value, "Z"), do: :ok, else: {:error, :invalid_timestamp}
  end

  defp validate_enum(value, allowed) do
    if value in allowed, do: :ok, else: {:error, :unsupported_value}
  end

  defp validate_digest(value) do
    if is_binary(value) and Regex.match?(@digest_pattern, value),
      do: :ok,
      else: {:error, :invalid_manifest_digest}
  end

  defp validate_payload_size(payload) when is_map(payload) do
    with {:ok, encoded} <- CanonicalJson.encode(payload) do
      if byte_size(encoded) <= ProtocolLimits.get(:max_payload_bytes),
        do: :ok,
        else: {:error, :payload_too_large}
    end
  end

  defp validate_payload_size(_payload), do: {:error, :invalid_payload}

  defp validate_command_payload(%{"operation" => operation} = envelope) do
    if operation in WorkerProtocol.manifest_operations() do
      validate_manifest_payload(envelope)
    else
      validate_control_payload(operation, envelope["payload"])
    end
  end

  defp validate_manifest_payload(%{"payload" => %{"manifest" => value} = payload} = envelope)
       when map_size(payload) == 1 do
    with {:ok, manifest} <- ExecutionManifest.from_map(value),
         :ok <- validate_manifest_binding(manifest, envelope) do
      validate_manifest_digest(manifest, envelope["manifest_digest"])
    end
  end

  defp validate_manifest_payload(_envelope), do: {:error, :manifest_payload_required}

  defp validate_manifest_binding(manifest, envelope) do
    bound? =
      manifest.project_id == envelope["project_id"] and
        manifest.feature_id == envelope["feature_id"] and
        manifest.run_id == envelope["run_id"] and
        manifest.attempt_number == envelope["attempt_number"]

    if bound?, do: :ok, else: {:error, :manifest_binding_mismatch}
  end

  defp validate_manifest_digest(manifest, digest) do
    if ExecutionManifest.digest(manifest) == digest,
      do: :ok,
      else: {:error, :manifest_digest_mismatch}
  end

  defp validate_control_payload("cancel", %{"reason" => reason} = payload)
       when map_size(payload) == 1,
       do: validate_text(reason)

  defp validate_control_payload("reconcile", payload) when map_size(payload) == 0, do: :ok
  defp validate_control_payload(_operation, _payload), do: {:error, :invalid_payload}

  defp validate_acknowledgement_reason("rejected", reason), do: validate_text(reason)
  defp validate_acknowledgement_reason(_status, nil), do: :ok
  defp validate_acknowledgement_reason(_status, reason), do: validate_text(reason)

  defp validate_text(value) do
    if is_binary(value) and value != "" and
         byte_size(value) <= ProtocolLimits.get(:max_text_bytes),
       do: :ok,
       else: {:error, :invalid_text}
  end

  defp validate_snapshot_attempts(attempts) when is_list(attempts) do
    with :ok <- validate_snapshot_count(attempts),
         :ok <- validate_snapshot_shapes(attempts) do
      validate_unique_snapshot_runs(attempts)
    end
  end

  defp validate_snapshot_attempts(_attempts), do: {:error, :invalid_snapshot}

  defp validate_snapshot_count(attempts) do
    if length(attempts) <= ProtocolLimits.get(:max_snapshot_attempts),
      do: :ok,
      else: {:error, :snapshot_too_large}
  end

  defp validate_snapshot_shapes(attempts) do
    Enum.reduce_while(attempts, :ok, fn attempt, :ok ->
      case validate_snapshot_attempt(attempt) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_snapshot_attempt(attempt) when is_map(attempt) do
    if Enum.sort(Map.keys(attempt)) == Enum.sort(@snapshot_attempt_keys) do
      validate_snapshot_attempt_fields(attempt)
    else
      {:error, :invalid_snapshot_attempt}
    end
  end

  defp validate_snapshot_attempt(_attempt), do: {:error, :invalid_snapshot_attempt}

  defp validate_snapshot_attempt_fields(attempt) do
    with :ok <- validate_ids(attempt, ~w(run_id command_id)),
         :ok <- validate_positive(attempt, ~w(attempt_number fence_token)),
         :ok <- validate_non_negative(attempt, ~w(last_sequence)),
         :ok <- validate_text(attempt["branch"]) do
      validate_enum(attempt["state"], WorkerProtocol.attempt_states())
    end
  end

  defp validate_unique_snapshot_runs(attempts) do
    run_ids = Enum.map(attempts, &Map.fetch!(&1, "run_id"))

    if length(run_ids) == length(Enum.uniq(run_ids)),
      do: :ok,
      else: {:error, :duplicate_snapshot_run}
  end

  defp validate_encoded_size(encoded) do
    if byte_size(encoded) <= ProtocolLimits.get(:max_envelope_bytes),
      do: :ok,
      else: {:error, :envelope_too_large}
  end
end
