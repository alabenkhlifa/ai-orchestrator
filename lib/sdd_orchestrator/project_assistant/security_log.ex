defmodule SddOrchestrator.ProjectAssistant.SecurityLog do
  @moduledoc """
  Fixed, minimized operational-security events for the project-assistant
  boundary (AC-19, AC-20's "content-free security outcomes" owned surface).

  Mirrors `SddOrchestrator.AIRuntime.SecurityLog` exactly: every line
  contains only an allowlisted event type, UTC occurrence time, coarse
  outcome, and a fresh non-secret correlation identifier. A prompt, answer,
  citation, repository path, source excerpt, project identifier,
  participant identifier, credential, or raw provider error is never
  inspected or interpolated — the same "content-free" guarantee this
  module's own name promises.

  Only a non-success emits. A successful panel open, confirmation, turn, or
  citation resolution produces no line at all, so this is an audit trail of
  denials and failures, never a running record of what a participant asked.

  The outcome vocabulary is closed — `:denied`, `:unavailable`, `:rejected`,
  `:failed` — and only an allowlisted reason atom can reach the first three.
  The final clause is the redaction mechanism: an unrecognised reason, a
  struct, a changeset, a binary, or a nested tuple becomes `:failed` without
  ever being inspected or encoded.

  Deployment logging infrastructure applies the approved 30-day
  operational-security-log expiry, the same ceiling `AIRuntime.SecurityLog`
  documents.
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
    :panel_open,
    :boundary_confirmation,
    :turn,
    :repository_observation,
    :citation_resolution,
    :redaction,
    :retention_sweep,
    :deletion
  ]

  @denied_reasons [
    :unauthorized,
    :source_denied,
    :not_a_member,
    :confirmation_required
  ]

  @unavailable_reasons [
    :setup_needed,
    :unavailable,
    :temporarily_limited,
    :worker_unavailable,
    :model_unavailable
  ]

  @rejected_reasons [
    :stale,
    :excluded,
    :unstable,
    :path_denied,
    :secret_detected,
    :invalid_question,
    :not_found,
    :tool_not_allowed,
    :budget_exhausted
  ]

  @doc """
  Emits one minimized failure event and returns the original result
  unchanged. A success emits nothing.
  """
  @spec audit(term(), atom(), keyword()) :: term()
  def audit(result, event_type, opts \\ []) when event_type in @events do
    emit(success?(result), result, event_type, opts)

    result
  end

  @doc "The fixed project-assistant security event types."
  @spec events() :: [atom()]
  def events, do: @events

  @doc "The deployment-enforced operational-security log expiry ceiling."
  @spec retention_days() :: pos_integer()
  def retention_days do
    DeploymentPrivacyProfile.retention_requirements().operational_security_logs_days
  end

  defp emit(true, _result, _event_type, _opts), do: :ok

  defp emit(false, result, event_type, opts) do
    entry = %Event{
      event_type: event_type,
      occurred_at: occurred_at(opts),
      outcome: outcome(result),
      correlation_id: correlation_id(opts)
    }

    Logger.warning("[project_assistant_security] " <> Jason.encode!(Map.from_struct(entry)))
  end

  defp success?(:ok), do: true

  defp success?(result)
       when is_tuple(result) and tuple_size(result) > 0 and elem(result, 0) == :ok,
       do: true

  defp success?(_result), do: false

  defp outcome({:error, reason}) when reason in @denied_reasons, do: :denied
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
