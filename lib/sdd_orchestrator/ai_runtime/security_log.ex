defmodule SddOrchestrator.AIRuntime.SecurityLog do
  @moduledoc """
  Fixed, minimized operational-security events for the AI-runtime boundary.

  Every line contains only an allowlisted event type, UTC occurrence time,
  coarse outcome, and a fresh non-secret correlation identifier. Credentials,
  provider account identity, worker-local profile references, owner-chosen
  labels, model or prompt content, raw provider or adapter text, amounts, and
  counters are never inspected or interpolated.

  Only a non-success emits. A successful operation produces no line at all, so
  the log is an audit trail of failures rather than a running record of what
  each account is doing.

  The outcome vocabulary is closed — `:denied`, `:paused`, `:unavailable`,
  `:rejected`, `:failed` — and only an allowlisted reason atom can reach the
  first four. The final clause is the redaction mechanism: an unrecognised
  reason, a struct, a changeset, a binary, or a nested tuple becomes `:failed`
  without ever being inspected or encoded.

  Deployment logging infrastructure applies the approved 30-day expiry.
  """

  require Logger

  alias SddOrchestrator.Privacy.DeploymentPrivacyProfile

  defmodule Event do
    @moduledoc false

    @enforce_keys [:event_type, :occurred_at, :outcome, :correlation_id]
    defstruct [:event_type, :occurred_at, :outcome, :correlation_id]

    @type t :: %__MODULE__{
            event_type: atom(),
            occurred_at: String.t(),
            outcome: atom(),
            correlation_id: Ecto.UUID.t()
          }
  end

  @events [
    :app_server_request,
    :catalog_refresh,
    :connection_link,
    :connection_revocation,
    :cost_reconciliation,
    :cost_reservation,
    :credential_removal,
    :observation_append,
    :quota_policy_evaluation,
    :quota_refresh,
    :retention_sweep,
    :session_pin,
    :worker_rpc_request
  ]

  @denied_reasons [
    :connection_required,
    :cross_account,
    :cross_workspace,
    :not_found,
    :revoked,
    :revoking,
    :unauthorized
  ]

  @paused_reasons [
    :insufficient_capacity,
    :paused
  ]

  @unavailable_reasons [
    :account_unavailable,
    :database_unavailable,
    :process_unavailable,
    :timeout,
    :unavailable,
    :worker_disconnected,
    :worker_unavailable
  ]

  @rejected_reasons [
    :capacity_conflict,
    :configuration_conflict,
    :credential_content,
    :duplicate_event,
    :duplicate_request,
    :duplicate_reservation,
    :enumeration_unsupported,
    :incompatible,
    :invalid_request,
    :invalid_response,
    :missing_price,
    :over_reconciliation,
    :payload_too_large,
    :stale,
    :stale_observation,
    :stale_price,
    :unknown_reservation,
    :unsupported_auth_mode,
    :unsupported_capability,
    :unsupported_method,
    :unsupported_version
  ]

  @doc """
  Emits one minimized failure event and returns the original result unchanged.

  A success emits nothing.
  """
  @spec audit(term(), atom(), keyword()) :: term()
  def audit(result, event_type, opts \\ []) when event_type in @events do
    emit(success?(result), result, event_type, opts)

    result
  end

  @doc "The fixed AI-runtime security event types."
  @spec events() :: [atom()]
  def events, do: @events

  @doc "The deployment-enforced operational-security log expiry ceiling."
  @spec retention_days() :: pos_integer()
  def retention_days do
    DeploymentPrivacyProfile.retention_requirements().operational_security_logs_days
  end

  # A success is silent: nothing about a completed operation is worth a line.
  defp emit(true, _result, _event_type, _opts), do: :ok

  defp emit(false, result, event_type, opts) do
    entry = %Event{
      event_type: event_type,
      occurred_at: occurred_at(opts),
      outcome: outcome(result),
      correlation_id: correlation_id(opts)
    }

    Logger.warning("[ai_runtime_security] " <> Jason.encode!(Map.from_struct(entry)))
  end

  defp success?(:ok), do: true

  defp success?(result)
       when is_tuple(result) and tuple_size(result) > 0 and elem(result, 0) == :ok,
       do: true

  defp success?(_result), do: false

  defp outcome({:error, reason}) when reason in @denied_reasons, do: :denied
  defp outcome({:error, reason}) when reason in @paused_reasons, do: :paused
  defp outcome({:error, reason}) when reason in @unavailable_reasons, do: :unavailable
  defp outcome({:error, reason}) when reason in @rejected_reasons, do: :rejected
  defp outcome(_result), do: :failed

  defp occurred_at(opts) do
    case Keyword.get(opts, :occurred_at) do
      %DateTime{} = occurred_at -> occurred_at
      _missing_or_invalid -> DateTime.utc_now()
    end
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp correlation_id(opts) do
    case Keyword.get(opts, :correlation_id) do
      correlation_id when is_binary(correlation_id) ->
        case Ecto.UUID.cast(correlation_id) do
          {:ok, valid} -> valid
          :error -> Ecto.UUID.generate()
        end

      _missing_or_invalid ->
        Ecto.UUID.generate()
    end
  end
end
