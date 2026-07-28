defmodule SddOrchestrator.Portability.SecurityLog do
  @moduledoc """
  Fixed, minimized operational-security events for backup and restoration.

  Every line contains only an allowlisted event type, UTC occurrence time,
  coarse outcome, and fresh non-secret correlation identifier. Results, errors,
  package data, project or repository identifiers, binding or worker data,
  filenames, paths, credentials, passphrases, and decrypted fields are never
  inspected or interpolated.
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
    :backup_generation,
    :repository_disconnection,
    :repository_reconnection,
    :restore_cancellation,
    :restore_commit,
    :restore_completion_cleanup,
    :restore_failure_cleanup,
    :restore_intake,
    :restore_validation
  ]

  @blocked_reasons [
    :identity_conflict,
    :name_conflict,
    :repository_conflict,
    :specification_conflict
  ]

  @rejected_reasons [
    :authorization_required,
    :destination_unavailable,
    :invalid_package_or_passphrase,
    :invalid_repository_identity,
    :invalid_request,
    :legacy_repository_identity,
    :not_found,
    :repository_mismatch,
    :repository_unavailable,
    :unauthorized_destination,
    :unauthorized_worker,
    :worker_unavailable,
    :worker_validation_failed
  ]

  @doc "Emits one minimized event and returns the original operation result."
  @spec audit(term(), atom(), keyword()) :: term()
  def audit(result, event_type, opts \\ []) when event_type in @events do
    entry = %Event{
      event_type: event_type,
      occurred_at: occurred_at(opts),
      outcome: outcome(result, event_type),
      correlation_id: correlation_id(opts)
    }

    Logger.log(
      level(entry.outcome),
      "[portability_security] " <> Jason.encode!(Map.from_struct(entry))
    )

    result
  end

  @doc "The fixed portability security event types."
  @spec events() :: [atom()]
  def events, do: @events

  @doc "The deployment-enforced operational-security log expiry ceiling."
  @spec retention_days() :: pos_integer()
  def retention_days do
    DeploymentPrivacyProfile.retention_requirements().operational_security_logs_days
  end

  defp outcome(:ok, :restore_cancellation), do: :cancelled

  defp outcome(result, _event_type)
       when is_tuple(result) and tuple_size(result) > 0 and elem(result, 0) == :ok,
       do: :succeeded

  defp outcome(:ok, _event_type), do: :succeeded

  defp outcome({:error, reason}, _event_type) when reason in @blocked_reasons,
    do: :blocked

  defp outcome({:error, reason}, _event_type) when reason in @rejected_reasons,
    do: :rejected

  defp outcome(_result, _event_type), do: :failed

  defp level(outcome) when outcome in [:succeeded, :cancelled], do: :info
  defp level(_outcome), do: :warning

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
