defmodule SddOrchestrator.HostedAccess.Sessions do
  @moduledoc """
  Hosted-session creation, authorization, activity, visibility, and revocation.

  Every device has an independent server record. Cookie credentials are
  resolved only through their protected digest, expiry is enforced before
  hosted data is returned, and revocation deletes the scoped record.
  """

  import Ecto.Query

  alias SddOrchestrator.Accounts.{
    HostedIdentity,
    HostedSession,
    PersonalWorkspace
  }

  alias SddOrchestrator.HostedAccess.SessionCookie
  alias SddOrchestrator.Repo

  @type access :: %{
          account: SddOrchestrator.Accounts.Account.t(),
          hosted_identity: HostedIdentity.t(),
          personal_workspace: PersonalWorkspace.t(),
          session: HostedSession.t(),
          session_cookie: SessionCookie.t()
        }

  @doc "Creates one independent session and its signed browser-cookie value."
  @spec create(HostedIdentity.t(), map() | keyword()) ::
          {:ok, HostedSession.t(), SessionCookie.t()} | {:error, Ecto.Changeset.t()}
  def create(%HostedIdentity{} = hosted_identity, device_context \\ %{}) do
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

  @doc """
  Resolves one signed cookie, rejects missing or expired records, and slides its
  activity timestamp without extending the absolute expiry.
  """
  @spec authenticate(term()) :: {:ok, access()} | :error
  def authenticate(signed_cookie) do
    with {:ok, token_digest} <- SessionCookie.digest_from_signed(signed_cookie),
         %HostedSession{} = session <- session_by_digest(token_digest),
         true <- session_active?(session),
         {:ok, touched_session} <- touch_active_session(session),
         {:ok, identity_result} <- load_identity_result(touched_session.hosted_identity_id) do
      {:ok,
       Map.merge(identity_result, %{
         session: touched_session,
         session_cookie: %SessionCookie{value: signed_cookie}
       })}
    else
      _invalid -> :error
    end
  end

  @doc "Lists this identity's unexpired device sessions without exposing credentials."
  @spec list_active(HostedIdentity.t(), term()) :: [
          %{session: HostedSession.t(), current?: boolean()}
        ]
  def list_active(%HostedIdentity{} = hosted_identity, current_cookie \\ nil) do
    current_digest =
      case SessionCookie.digest_from_signed(current_cookie) do
        {:ok, digest} -> digest
        :error -> nil
      end

    from(session in HostedSession,
      where:
        session.hosted_identity_id == ^hosted_identity.id and
          session.expires_at > ^now(),
      order_by: [desc: session.last_seen_at, desc: session.inserted_at]
    )
    |> Repo.all()
    |> Enum.map(fn session ->
      %{session: session, current?: secure_equal?(session.token_digest, current_digest)}
    end)
  end

  @doc "Deletes one device session only when it belongs to the authorized identity."
  @spec revoke(HostedIdentity.t(), Ecto.UUID.t()) :: :ok
  def revoke(%HostedIdentity{} = hosted_identity, session_id) do
    with {:ok, session_id} <- Ecto.UUID.cast(session_id) do
      Repo.delete_all(
        from(session in HostedSession,
          where:
            session.id == ^session_id and
              session.hosted_identity_id == ^hosted_identity.id
        )
      )
    end

    :ok
  end

  @doc "Deletes only the session represented by this signed cookie."
  @spec revoke_current(term()) :: :ok
  def revoke_current(signed_cookie) do
    with {:ok, token_digest} <- SessionCookie.digest_from_signed(signed_cookie) do
      Repo.delete_all(
        from(session in HostedSession, where: session.token_digest == ^token_digest)
      )
    end

    :ok
  end

  @doc "Deletes every device session for one authorized hosted identity."
  @spec revoke_all(HostedIdentity.t()) :: :ok
  def revoke_all(%HostedIdentity{} = hosted_identity) do
    Repo.delete_all(
      from(session in HostedSession,
        where: session.hosted_identity_id == ^hosted_identity.id
      )
    )

    :ok
  end

  defp session_by_digest(token_digest) do
    Repo.one(
      from(session in HostedSession,
        where: session.token_digest == ^token_digest
      )
    )
  end

  defp session_active?(session) do
    DateTime.compare(session.expires_at, now()) == :gt
  end

  defp touch_active_session(session) do
    now = now()

    case Repo.update_all(
           from(candidate in HostedSession,
             where:
               candidate.id == ^session.id and
                 candidate.expires_at > ^now
           ),
           set: [last_seen_at: now, updated_at: now]
         ) do
      {1, _rows} -> {:ok, %{session | last_seen_at: now, updated_at: now}}
      {0, _rows} -> :error
    end
  end

  defp load_identity_result(hosted_identity_id) do
    case HostedIdentity
         |> Repo.get(hosted_identity_id)
         |> Repo.preload(:account) do
      %HostedIdentity{account: %{state: :active} = account} = hosted_identity ->
        personal_workspace =
          PersonalWorkspace
          |> Repo.get_by!(account_id: account.id)
          |> Repo.preload(:workspace)

        {:ok,
         %{
           account: account,
           hosted_identity: hosted_identity,
           personal_workspace: personal_workspace
         }}

      _missing_or_disabled ->
        :error
    end
  end

  defp secure_equal?(_digest, nil), do: false

  defp secure_equal?(left, right) when is_binary(left) and is_binary(right) do
    byte_size(left) == byte_size(right) and :crypto.hash_equals(left, right)
  end

  defp context_value(context, key) when is_map(context), do: Map.get(context, key)
  defp context_value(context, key) when is_list(context), do: Keyword.get(context, key)
  defp context_value(_context, _key), do: nil

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
