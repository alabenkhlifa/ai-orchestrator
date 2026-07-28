defmodule SddOrchestrator.IdentityLinking.Audit do
  @moduledoc """
  Append-only security-audit trail for identity linking.

  Every candidate detection, proof, confirmation, and merge outcome is written as
  one structured log line on the operational security-audit stream (whose 30-day
  retention is enforced by the deployment's log infrastructure). Payloads are
  restricted to a non-sensitive allowlist — event, outcome/reason, and opaque
  attempt/workspace ids — so a secondary email, verified email, token, secret,
  project name, or repository identifier can never reach the audit trail, and a
  failure is diagnosable without disclosing the matched account.
  """
  require Logger

  @tag "identity_linking_audit"

  # Only these keys may appear in an audit payload. Anything else is dropped, so a
  # careless call site can never leak personal data or a secret into the trail.
  @allowed_keys ~w(event outcome reason attempt_id merge_event_id source_workspace_id
                    surviving_workspace_id)a

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
      |> Enum.map(fn {k, v} -> "#{k}=#{format(v)}" end)
      |> Enum.join(" ")

    Logger.info("[#{@tag}] #{payload}")
    :ok
  end

  @doc "The log tag prefixing every identity-linking audit line."
  def tag, do: @tag

  defp format(value) when is_atom(value), do: Atom.to_string(value)
  defp format(value), do: to_string(value)
end
