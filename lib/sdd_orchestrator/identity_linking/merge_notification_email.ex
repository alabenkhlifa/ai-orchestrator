defmodule SddOrchestrator.IdentityLinking.MergeNotificationEmail do
  @moduledoc """
  Builds the notification sent to the surviving hosted identity after a GitHub
  sign-in is linked to its account.

  The body describes the identity change so the user is aware of it, and names no
  other account, project, repository, or secret.
  """
  import Swoosh.Email

  @spec build(String.t()) :: Swoosh.Email.t()
  def build(delivery_email) when is_binary(delivery_email) do
    new()
    |> to(delivery_email)
    |> from({"SDD Orchestrator", passwordless_config(:from_email)})
    |> subject("A GitHub sign-in was linked to your SDD Orchestrator account")
    |> text_body(body())
  end

  defp body do
    """
    A GitHub sign-in method was just linked to your SDD Orchestrator account, and
    your projects were combined into it. You can now sign in with either your
    email link or GitHub.

    If you did not do this, contact support right away.
    """
  end

  defp passwordless_config(key) do
    :sdd_orchestrator
    |> Application.fetch_env!(:passwordless)
    |> Keyword.fetch!(key)
  end
end
