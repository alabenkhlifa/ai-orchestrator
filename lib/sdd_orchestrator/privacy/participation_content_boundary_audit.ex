defmodule SddOrchestrator.Privacy.ParticipationContentBoundaryAudit do
  @moduledoc """
  Minimized, allowlisted diagnostic log for participation-boundary content
  and destination minimization refusals (specs/26 Task 4, AC-04).

  `SddOrchestrator.Privacy.ParticipationContentBoundary` calls this module
  every time it refuses content or a destination crossing a participation
  persistence, notification, delivery, support, logging, export, or
  processor boundary. Following the same allowlisted-payload discipline as
  `SddOrchestrator.Privacy.DeliveryContentBoundaryAudit` and
  `SddOrchestrator.Privacy.ParticipationSupportAudit`, only a closed-vocabulary
  event name, which check fired, the name of the offending field, and the
  outcome may appear. The credential, email address, or raw field value that
  triggered the refusal is never a permitted key, so a careless call site
  cannot leak it into this trail — it can only name the field that carried
  it.

  Logged at `:warning`, matching this codebase's other security-audit
  streams, so a minimization refusal is never silently dropped by an
  operator's default log level.
  """
  require Logger

  @tag "participation_content_boundary"

  # Only these keys may appear in a payload. Anything else — in particular the
  # matched credential, email, or rejected field value itself — is dropped, so
  # a careless call site can never leak it into the trail.
  @allowed_keys ~w(event check field outcome)a

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

  @doc "The log tag prefixing every participation-content-boundary audit line."
  @spec tag() :: String.t()
  def tag, do: @tag

  @doc "The complete allowlist of keys an audit payload may carry."
  @spec allowed_keys() :: [atom()]
  def allowed_keys, do: @allowed_keys

  defp format(nil), do: "nil"
  defp format(value) when is_atom(value), do: Atom.to_string(value)
  defp format(value), do: to_string(value)
end
