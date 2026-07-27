defmodule SddOrchestrator.HostedAccess.MagicLinkEmail do
  @moduledoc "Builds the delivery-only magic-link email."

  import Swoosh.Email

  alias SddOrchestrator.Accounts.MagicLinkAttempt

  @spec build(MagicLinkAttempt.t(), String.t()) :: Swoosh.Email.t()
  def build(%MagicLinkAttempt{} = attempt, raw_token) do
    new()
    |> to(attempt.delivery_email)
    |> from({"SDD Orchestrator", passwordless_config(:from_email)})
    |> subject("Your SDD Orchestrator sign-in link")
    |> text_body(body(verification_url(attempt, raw_token)))
  end

  @spec verification_url(MagicLinkAttempt.t(), String.t()) :: String.t()
  def verification_url(%MagicLinkAttempt{} = attempt, raw_token) do
    query = URI.encode_query(%{"attempt" => attempt.id, "token" => raw_token})
    "#{passwordless_config(:app_origin)}/hosted/access/verify?#{query}"
  end

  defp body(url) do
    """
    Use this link to sign in to SDD Orchestrator:

    #{url}

    This link expires in 15 minutes and can be used once. If you did not request
    it, you can ignore this email.
    """
  end

  defp passwordless_config(key) do
    :sdd_orchestrator
    |> Application.fetch_env!(:passwordless)
    |> Keyword.fetch!(key)
  end
end
