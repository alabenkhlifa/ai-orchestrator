defmodule SddOrchestrator.HostedAccessFixtures do
  @moduledoc "Test fixtures for passwordless hosted identities and workspaces."

  alias SddOrchestrator.Accounts.{ExternalIdentity, MagicLinkAttempt}
  alias SddOrchestrator.{HostedAccess, Repo}

  @doc "Creates or restores a hosted identity for a unique verified email."
  def hosted_identity_fixture(attrs \\ %{}) do
    email =
      Map.get_lazy(attrs, :email, fn ->
        "hosted-#{System.unique_integer([:positive])}@example.com"
      end)

    {:ok, result} = HostedAccess.restore_or_create_identity(email)
    result
  end

  @doc """
  Creates an active protected attempt and returns its delivery-only raw token.

  Verification tests receive the raw credential separately because the
  application record contains only its salted digest.
  """
  def magic_link_attempt_fixture(attrs \\ %{}) do
    email =
      Map.get_lazy(attrs, :email, fn ->
        "attempt-#{System.unique_integer([:positive])}@example.com"
      end)

    {:ok, email_attrs} = ExternalIdentity.normalize_email(email)
    raw_token = Map.get_lazy(attrs, :raw_token, &new_raw_token/0)
    salt = Map.get_lazy(attrs, :token_salt, fn -> :crypto.strong_rand_bytes(32) end)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    attempt_attrs = %{
      token_digest: :crypto.hash(:sha256, salt <> raw_token),
      token_salt: salt,
      email_key: email_attrs.subject_key,
      delivery_email: email_attrs.display_identifier,
      delivery_status: Map.get(attrs, :delivery_status, "sent"),
      expires_at: Map.get(attrs, :expires_at, DateTime.add(now, 15 * 60, :second))
    }

    attempt =
      %MagicLinkAttempt{}
      |> MagicLinkAttempt.changeset(attempt_attrs)
      |> Repo.insert!()

    %{attempt: attempt, raw_token: raw_token}
  end

  defp new_raw_token do
    :crypto.strong_rand_bytes(32)
    |> Base.url_encode64(padding: false)
  end
end
