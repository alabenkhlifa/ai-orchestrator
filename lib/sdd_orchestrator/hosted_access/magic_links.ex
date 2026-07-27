defmodule SddOrchestrator.HostedAccess.MagicLinks do
  @moduledoc """
  Account-neutral magic-link request and resend service.

  Every caller receives the same acknowledgement. Only valid, allowed requests
  create an attempt, and the raw token is handed directly to the delivery
  boundary without being returned or persisted.
  """

  import Ecto.Query

  require Logger

  alias Ecto.Multi

  alias SddOrchestrator.Accounts.{ExternalIdentity, MagicLinkAttempt}

  alias SddOrchestrator.HostedAccess.{
    MagicLinkEmail,
    RateLimiter
  }

  alias SddOrchestrator.Repo

  @acknowledgement {:ok, %{status: :accepted}}

  @spec request(term(), map() | keyword()) :: {:ok, %{status: :accepted}}
  def request(email, context \\ %{}) do
    with {:ok, email_attrs} <- ExternalIdentity.normalize_email(email),
         true <- RateLimiter.allow?(email_attrs.subject_key, context_value(context, :ip_address)) do
      issue(email_attrs)
    end

    @acknowledgement
  end

  defp issue(email_attrs) do
    raw_token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    salt = :crypto.strong_rand_bytes(32)
    digest = :crypto.hash(:sha256, salt <> raw_token)
    now = now()

    attrs = %{
      token_digest: digest,
      token_salt: salt,
      email_key: email_attrs.subject_key,
      delivery_email: email_attrs.display_identifier,
      delivery_status: "pending",
      expires_at: DateTime.add(now, ttl_seconds(), :second)
    }

    Multi.new()
    |> Multi.run(:email_lock, fn repo, _changes ->
      acquire_email_lock(repo, email_attrs.subject_key)
    end)
    |> Multi.update_all(
      :invalidate_previous,
      active_attempts(email_attrs.subject_key),
      set: [invalidated_at: now, updated_at: now]
    )
    |> Multi.insert(:attempt, MagicLinkAttempt.changeset(%MagicLinkAttempt{}, attrs))
    |> Repo.transaction()
    |> case do
      {:ok, %{attempt: attempt}} ->
        deliver(attempt, raw_token)

      {:error, _step, _reason, _changes} ->
        Logger.warning("magic_link_attempt_creation_failed")
    end
  end

  defp deliver(attempt, raw_token) do
    email = MagicLinkEmail.build(attempt, raw_token)
    delivery = Application.fetch_env!(:sdd_orchestrator, :magic_link_delivery)

    case delivery.deliver(email) do
      {:ok, _metadata} ->
        set_delivery_result(attempt, "sent", nil)

      {:error, _reason} ->
        set_delivery_result(attempt, "failed", "delivery_failed")
        Logger.warning("magic_link_delivery_failed attempt_id=#{attempt.id}")
    end
  rescue
    _error ->
      set_delivery_result(attempt, "failed", "delivery_failed")
      Logger.warning("magic_link_delivery_failed attempt_id=#{attempt.id}")
  end

  defp set_delivery_result(attempt, status, failure_code) do
    attempt
    |> MagicLinkAttempt.changeset(%{
      delivery_status: status,
      failure_code: failure_code
    })
    |> Repo.update()
  end

  defp active_attempts(email_key) do
    from attempt in MagicLinkAttempt,
      where:
        attempt.email_key == ^email_key and is_nil(attempt.consumed_at) and
          is_nil(attempt.invalidated_at)
  end

  defp acquire_email_lock(repo, email_key) do
    case Ecto.Adapters.SQL.query(repo, "SELECT pg_advisory_xact_lock($1)", [
           advisory_lock_key(email_key)
         ]) do
      {:ok, _result} -> {:ok, :locked}
      {:error, reason} -> {:error, reason}
    end
  end

  defp advisory_lock_key(email_key) do
    <<unsigned::unsigned-64, _rest::binary>> = :crypto.hash(:sha256, email_key)

    if unsigned > 9_223_372_036_854_775_807 do
      unsigned - 18_446_744_073_709_551_616
    else
      unsigned
    end
  end

  defp ttl_seconds do
    :sdd_orchestrator
    |> Application.fetch_env!(:passwordless)
    |> Keyword.fetch!(:magic_link_ttl_seconds)
  end

  defp context_value(context, key) when is_map(context), do: Map.get(context, key)
  defp context_value(context, key) when is_list(context), do: Keyword.get(context, key)
  defp context_value(_context, _key), do: nil

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
