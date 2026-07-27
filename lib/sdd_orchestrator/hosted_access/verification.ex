defmodule SddOrchestrator.HostedAccess.Verification do
  @moduledoc """
  Atomic magic-link verification and initial hosted-session creation.

  Invalid, expired, replayed, mismatched, and internal-failure paths share one
  safe result. Identity, workspace, attempt consumption, and session creation
  commit together or not at all.
  """

  import Ecto.Query

  alias SddOrchestrator.Accounts.{HostedSession, MagicLinkAttempt}

  alias SddOrchestrator.HostedAccess
  alias SddOrchestrator.HostedAccess.SessionCookie
  alias SddOrchestrator.Repo

  @failure {:error, :invalid_or_expired}

  @type verification_result :: %{
          account: SddOrchestrator.Accounts.Account.t(),
          external_identity: SddOrchestrator.Accounts.ExternalIdentity.t(),
          hosted_identity: SddOrchestrator.Accounts.HostedIdentity.t(),
          personal_workspace: SddOrchestrator.Accounts.PersonalWorkspace.t(),
          session: HostedSession.t(),
          session_cookie: SessionCookie.t()
        }

  @spec verify(term(), term(), map() | keyword()) ::
          {:ok, verification_result()} | {:error, :invalid_or_expired}
  def verify(attempt_id, raw_token, device_context \\ %{}) do
    with {:ok, attempt_id} <- cast_attempt_id(attempt_id),
         true <- valid_token_shape?(raw_token) do
      verify_transaction(attempt_id, raw_token, device_context)
    else
      _invalid -> @failure
    end
  end

  defp verify_transaction(attempt_id, raw_token, device_context) do
    Repo.transaction(fn ->
      with %MagicLinkAttempt{} = attempt <- lock_attempt(attempt_id),
           :ok <- validate_attempt(attempt, raw_token),
           {:ok, identity} <- HostedAccess.restore_or_create_identity(attempt.delivery_email),
           {:ok, session, session_cookie} <-
             create_session(identity.hosted_identity, device_context),
           {1, _rows} <- consume_attempt(attempt) do
        Map.merge(identity, %{session: session, session_cookie: session_cookie})
      else
        _failure -> Repo.rollback(:invalid_or_expired)
      end
    end)
    |> case do
      {:ok, result} -> {:ok, result}
      {:error, _reason} -> @failure
    end
  rescue
    _error -> @failure
  end

  defp lock_attempt(attempt_id) do
    Repo.one(
      from attempt in MagicLinkAttempt,
        where: attempt.id == ^attempt_id,
        lock: "FOR UPDATE"
    )
  end

  defp validate_attempt(attempt, raw_token) do
    expected_digest = :crypto.hash(:sha256, attempt.token_salt <> raw_token)
    now = now()

    valid? =
      attempt.delivery_status == "sent" and
        is_nil(attempt.consumed_at) and
        is_nil(attempt.invalidated_at) and
        DateTime.compare(attempt.expires_at, now) == :gt and
        :crypto.hash_equals(expected_digest, attempt.token_digest)

    if valid?, do: :ok, else: :error
  end

  defp create_session(hosted_identity, device_context) do
    now = now()
    {token_digest, session_cookie} = SessionCookie.issue()

    attrs = %{
      token_digest: token_digest,
      hosted_identity_id: hosted_identity.id,
      user_agent_family: context_value(device_context, :user_agent_family),
      os_family: context_value(device_context, :os_family),
      first_seen_at: now,
      last_seen_at: now,
      expires_at: DateTime.add(now, SessionCookie.session_lifetime_seconds(), :second)
    }

    case %HostedSession{} |> HostedSession.changeset(attrs) |> Repo.insert() do
      {:ok, session} -> {:ok, session, session_cookie}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp consume_attempt(attempt) do
    now = now()

    Repo.update_all(
      from(candidate in MagicLinkAttempt,
        where:
          candidate.id == ^attempt.id and candidate.delivery_status == "sent" and
            is_nil(candidate.consumed_at) and is_nil(candidate.invalidated_at) and
            candidate.expires_at > ^now
      ),
      set: [consumed_at: now, updated_at: now]
    )
  end

  defp cast_attempt_id(attempt_id) do
    case Ecto.UUID.cast(attempt_id) do
      {:ok, cast_id} -> {:ok, cast_id}
      :error -> :error
    end
  end

  defp valid_token_shape?(raw_token) when is_binary(raw_token) do
    case Base.url_decode64(raw_token, padding: false) do
      {:ok, decoded} -> byte_size(decoded) == 32
      :error -> false
    end
  end

  defp valid_token_shape?(_raw_token), do: false

  defp context_value(context, key) when is_map(context), do: Map.get(context, key)
  defp context_value(context, key) when is_list(context), do: Keyword.get(context, key)
  defp context_value(_context, _key), do: nil

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
