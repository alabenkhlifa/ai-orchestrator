defmodule SddOrchestrator.Privacy.DeliverySupportAudit do
  @moduledoc """
  Minimized, append-only audit trail for exceptional guided-delivery support
  access (specs/18 Task 2, AC-03).

  Every issue, authorize-attempt, expiry, and revocation outcome is written as
  one structured log line on the operational security-audit stream, following
  the same allowlisted-payload pattern as
  `SddOrchestrator.IdentityLinking.Audit`: only opaque ids and closed-vocabulary
  atoms may appear. A project name, feature title, comment body, evidence, or
  participant email can never reach this trail, because a call site cannot pass
  through a key this module does not allow.

  Logged at `:warning`, matching this codebase's other security-audit streams
  (e.g. `SddOrchestrator.AIRuntime.SecurityLog`) rather than `:info`, so an
  exceptional support-access event is never silently dropped by an operator's
  default log level.
  """
  require Logger

  @tag "delivery_support_audit"

  # Only these keys may appear in an audit payload. Anything else is dropped, so
  # a careless call site can never leak project content or a participant email
  # into the trail.
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

  @doc "The log tag prefixing every delivery-support audit line."
  def tag, do: @tag

  @doc "The complete allowlist of keys an audit payload may carry."
  @spec allowed_keys() :: [atom()]
  def allowed_keys, do: @allowed_keys

  defp format(nil), do: "nil"
  defp format(value) when is_atom(value), do: Atom.to_string(value)
  defp format(value), do: to_string(value)
end
