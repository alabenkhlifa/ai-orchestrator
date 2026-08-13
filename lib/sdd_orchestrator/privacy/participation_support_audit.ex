defmodule SddOrchestrator.Privacy.ParticipationSupportAudit do
  @moduledoc """
  Minimized, append-only audit trail for exceptional participation support
  access (specs/26 Task 3, AC-03).

  Every issue, authorize-attempt, expiry, and revocation outcome is written
  as one structured log line on the operational security-audit stream,
  following the same allowlisted-payload pattern as
  `SddOrchestrator.Privacy.DeliverySupportAudit`: only opaque ids and
  closed-vocabulary atoms may appear. design.md's "Data and Access
  Boundaries" requires a support audit entry to record "actor, purpose
  category, scope, issue time, expiry, revocation state, and decision
  outcome without project content, participant email, credentials, or secret
  values" — a project name, invitation email, participant display name, or
  invitation credential digest can never reach this trail, because a call
  site cannot pass through a key this module does not allow.

  Logged at `:warning`, matching this codebase's other security-audit
  streams (e.g. `SddOrchestrator.Privacy.DeliverySupportAudit`,
  `SddOrchestrator.AIRuntime.SecurityLog`) rather than `:info`, so an
  exceptional support-access event is never silently dropped by an
  operator's default log level.
  """
  require Logger

  @tag "participation_support_audit"

  # Only these keys may appear in an audit payload. Anything else is dropped,
  # so a careless call site can never leak project content, a participant
  # email, or an invitation credential into the trail.
  @allowed_keys ~w(event outcome reason elevation_id project_id operations_account_id
                    revoked_by_account_id purpose scope)a

  @doc """
  Emits one audit event. `metadata` is filtered to the non-sensitive allowlist
  before logging.
  """
  @spec event(atom(), map()) :: :ok
  def event(name, metadata \\ %{}) when is_atom(name) do
    payload =
      metadata
      |> Map.put(:event, name)
      |> Map.take(@allowed_keys)
      |> Enum.map_join(" ", fn {k, v} -> "#{k}=#{format(v)}" end)

    Logger.warning("[#{@tag}] #{payload}")
    :ok
  end

  @doc "The log tag prefixing every participation-support audit line."
  def tag, do: @tag

  @doc "The complete allowlist of keys an audit payload may carry."
  @spec allowed_keys() :: [atom()]
  def allowed_keys, do: @allowed_keys

  defp format(nil), do: "nil"
  defp format(value) when is_atom(value), do: Atom.to_string(value)
  defp format(value), do: to_string(value)
end
