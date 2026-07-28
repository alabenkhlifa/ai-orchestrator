defmodule SddOrchestrator.IdentityLinking.LinkProofEmail do
  @moduledoc """
  Builds the passwordless-proof email that confirms the user controls the email of
  the account being linked. The raw token travels only in this email link and is
  never stored; the challenge id locates the attempt.
  """
  import Swoosh.Email

  @spec build(String.t(), String.t(), String.t()) :: Swoosh.Email.t()
  def build(delivery_email, challenge_id, raw_token)
      when is_binary(delivery_email) and is_binary(challenge_id) and is_binary(raw_token) do
    new()
    |> to(delivery_email)
    |> from({"SDD Orchestrator", passwordless_config(:from_email)})
    |> subject("Confirm linking your GitHub sign-in")
    |> text_body(body(verify_url(challenge_id, raw_token)))
  end

  @spec verify_url(String.t(), String.t()) :: String.t()
  def verify_url(challenge_id, raw_token) do
    query = URI.encode_query(%{"challenge" => challenge_id, "token" => raw_token})
    "#{passwordless_config(:app_origin)}/identity/link/verify?#{query}"
  end

  defp body(url) do
    """
    You started linking a GitHub sign-in to your SDD Orchestrator account. Confirm
    you control this email address by opening the link below:

    #{url}

    This link expires in 15 minutes and can be used once. If you did not start this,
    you can ignore this email and nothing will change.
    """
  end

  defp passwordless_config(key) do
    :sdd_orchestrator
    |> Application.fetch_env!(:passwordless)
    |> Keyword.fetch!(key)
  end
end
