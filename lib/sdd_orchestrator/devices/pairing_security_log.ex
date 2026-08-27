defmodule SddOrchestrator.Devices.PairingSecurityLog do
  @moduledoc """
  Fixed, content-free security outcomes for anonymous pairing-code issuance.

  Issuance is the one pairing step no account stands behind, so its volume and
  refusals are worth seeing. Nothing identifying is worth recording to see them:
  events carry no code, no secret, no workspace, no worker, and no network
  identifier, so the log cannot be turned into a record of who asked or from
  where. Deployment logging infrastructure applies the approved expiry.
  """

  require Logger

  @events [:issue_code]

  @spec audit(term(), atom()) :: term()
  def audit(result, event) when event in @events do
    Logger.info("[pairing_security] event=#{event} outcome=#{outcome(result)}")

    result
  end

  defp outcome({:ok, _issued}), do: "issued"
  defp outcome({:error, :throttled}), do: "throttled"
  defp outcome({:error, _reason}), do: "refused"
end
