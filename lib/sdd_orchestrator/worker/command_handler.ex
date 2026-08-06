defmodule SddOrchestrator.Worker.CommandHandler do
  @moduledoc """
  Decides and durably records the outcome of one inbound "command" push.

  The envelope handed to `handle_command/3` has already crossed the control
  plane's own protocol-codec and execution-manifest validation before it was
  ever pushed to this worker — the checks below are this worker's own
  independent read of that same envelope against what it has itself already
  accepted, not a re-implementation of that validation. A genuinely remote
  worker has no in-process access to the control plane's protocol or
  manifest modules (see `SddOrchestrator.Worker.GatewayConnection`'s
  moduledoc), so this module never references them — only plain map fields
  read off the already-decoded envelope.

  Exactly-once acceptance is this worker's own property, checked here before
  anything else: the control plane's own outbox separately absorbs a
  duplicate acknowledgement so its record stays correct even if two answers
  arrive, but that alone would not stop this worker from validating and
  accepting the same command twice on a redelivery. Comparing the incoming
  `command_id` against `SddOrchestrator.Worker.RunState` first is what makes
  a redelivered command a no-op here rather than a second acceptance.

  Preparing a workspace, acquiring the single-process execution lock,
  launching a coding agent, and handling `cancel`, `resume`, `retry`, and
  `reconcile` in full are later work. Validating, acknowledging, and durably
  recording a `start` command — and refusing one that is stale or
  superseded — is everything this module does today.
  """

  alias SddOrchestrator.Worker.RunState

  @digest_pattern ~r/\A[0-9a-f]{64}\z/

  @doc """
  Decides the outcome of one inbound command envelope and returns the
  acknowledgement envelope to push back.

  `protocol_version` is the worker's own already-hardcoded announced version
  (see `SddOrchestrator.Worker.GatewayConnection.protocol_version/0`) —
  passed in rather than duplicated here. `home_override` is forwarded to
  `SddOrchestrator.Worker.RunState`, letting a caller isolate storage (e.g.
  under test); production callers never pass it and use the real worker
  home directory.

  A command whose durable local state cannot be read is refused rather than
  guessed at: this worker cannot safely tell a fresh command from a
  duplicate or a superseded one without trustworthy local state.
  """
  @spec handle_command(map(), pos_integer(), String.t() | nil) :: map()
  def handle_command(envelope, protocol_version, home_override \\ nil) do
    case RunState.load(home_override) do
      {:ok, record} ->
        decide(envelope, record, protocol_version, home_override)

      {:error, _reason} ->
        ack(envelope, protocol_version, "rejected", "local_run_state_unavailable")
    end
  end

  defp decide(envelope, record, protocol_version, home_override) do
    case envelope["operation"] do
      "start" ->
        handle_start(envelope, record, protocol_version, home_override)

      other ->
        # `cancel`, `resume`, `retry`, and `reconcile` are Task 11's full
        # behaviour. Refusing cleanly here means an unhandled operation is
        # never silently dropped and never crashes this process.
        ack(envelope, protocol_version, "rejected", "operation_not_yet_supported:#{other}")
    end
  end

  defp handle_start(envelope, %{current: current} = record, protocol_version, home_override) do
    cond do
      duplicate?(current, envelope) ->
        ack(envelope, protocol_version, "duplicate", nil)

      stale_fence?(current, envelope) ->
        ack(envelope, protocol_version, "rejected", "stale_fence_token")

      superseded_attempt?(current, envelope) ->
        ack(envelope, protocol_version, "rejected", "superseded_attempt")

      true ->
        accept(envelope, record, protocol_version, home_override)
    end
  end

  defp duplicate?(nil, _envelope), do: false
  defp duplicate?(current, envelope), do: current.command_id == envelope["command_id"]

  # A stale or superseded incoming command changes nothing: the currently
  # recorded entry already reflects the newer fence, so leaving it untouched
  # is itself the durable fact that nothing runs under the older one.
  defp stale_fence?(nil, _envelope), do: false

  defp stale_fence?(current, envelope) do
    current.run_id == envelope["run_id"] and envelope["fence_token"] < current.fence_token
  end

  defp superseded_attempt?(nil, _envelope), do: false

  defp superseded_attempt?(current, envelope) do
    current.run_id == envelope["run_id"] and envelope["attempt_number"] < current.attempt_number
  end

  defp accept(envelope, record, protocol_version, home_override) do
    case validate_manifest(envelope) do
      :ok ->
        new_current = %RunState{
          command_id: envelope["command_id"],
          operation: envelope["operation"],
          project_id: envelope["project_id"],
          feature_id: envelope["feature_id"],
          run_id: envelope["run_id"],
          attempt_number: envelope["attempt_number"],
          fence_token: envelope["fence_token"],
          manifest_digest: envelope["manifest_digest"],
          last_sequence: 0,
          agent_thread_ref: nil,
          lifecycle: "accepted"
        }

        updated = %{current: new_current, previous: superseded(record.current, envelope)}

        # Written before the acknowledgement is pushed, so a crash between
        # accepting and acknowledging leaves durable state a redelivery can
        # recover from rather than losing the acceptance silently.
        :ok = RunState.store(updated, home_override)

        ack(envelope, protocol_version, "accepted", nil)

      {:error, reason} ->
        ack(envelope, protocol_version, "rejected", reason)
    end
  end

  # A prior current entry for the same run is genuinely superseded by this
  # acceptance (never a different run's attempt, and never itself — that
  # path is the duplicate check above). Its lifecycle transitions to
  # "stopped": the durable fact that nothing runs under its fence anymore,
  # even though no real process exists yet to kill.
  defp superseded(nil, _envelope), do: nil

  defp superseded(%RunState{run_id: run_id} = current, %{"run_id" => run_id}),
    do: %{current | lifecycle: "stopped"}

  defp superseded(_current_for_another_run, _envelope), do: nil

  # Structural cross-checks only: the manifest already passed the control
  # plane's own field validation, binding check, and digest match before
  # this envelope was ever delivered. This is this worker's own independent
  # read of that same content — not a re-derivation of the digest itself,
  # which would require re-encoding the manifest the same canonical way the
  # control plane does and duplicating that module entirely.
  defp validate_manifest(%{"payload" => %{"manifest" => manifest}} = envelope)
       when is_map(manifest) do
    with :ok <- validate_digest(envelope["manifest_digest"]) do
      validate_binding(manifest, envelope)
    end
  end

  defp validate_manifest(_envelope), do: {:error, "manifest_absent"}

  defp validate_digest(value) do
    if is_binary(value) and Regex.match?(@digest_pattern, value),
      do: :ok,
      else: {:error, "invalid_manifest_digest"}
  end

  defp validate_binding(manifest, envelope) do
    bound? =
      manifest["project_id"] == envelope["project_id"] and
        manifest["feature_id"] == envelope["feature_id"] and
        manifest["run_id"] == envelope["run_id"] and
        manifest["attempt_number"] == envelope["attempt_number"]

    if bound?, do: :ok, else: {:error, "manifest_binding_mismatch"}
  end

  defp ack(envelope, protocol_version, status, reason) do
    %{
      "type" => "acknowledgement",
      "protocol_version" => protocol_version,
      "command_id" => envelope["command_id"],
      "run_id" => envelope["run_id"],
      "attempt_number" => envelope["attempt_number"],
      "fence_token" => envelope["fence_token"],
      "status" => status,
      "reason" => reason,
      "acknowledged_at" => DateTime.to_iso8601(DateTime.utc_now())
    }
  end
end
