defmodule SddOrchestrator.HostedAccess.Recovery do
  @moduledoc """
  Recovery seam for an already verified, previously linked sign-in method.

  This module does not authenticate providers. It accepts only the persisted
  `ExternalIdentity` returned by an upstream provider-verification boundary and
  never changes the verified email.
  """

  alias SddOrchestrator.Accounts.{ExternalIdentity, PersonalWorkspace}
  alias SddOrchestrator.HostedAccess.Sessions
  alias SddOrchestrator.Repo

  @failure {:error, :access_unavailable}

  @spec restore(term(), map() | keyword()) ::
          {:ok, Sessions.access()} | {:error, :access_unavailable}
  def restore(verified_method, device_context \\ %{})

  def restore(%ExternalIdentity{id: id, provider: provider}, device_context)
      when provider != "email" do
    with %ExternalIdentity{provider: ^provider, verified_at: verified_at} = external_identity
         when not is_nil(verified_at) <- Repo.get(ExternalIdentity, id),
         external_identity <-
           Repo.preload(external_identity, hosted_identity: :account),
         hosted_identity <- external_identity.hosted_identity,
         %{state: :active} = account <- hosted_identity.account,
         %PersonalWorkspace{} = personal_workspace <-
           Repo.get_by(PersonalWorkspace, account_id: account.id),
         personal_workspace <- Repo.preload(personal_workspace, :workspace),
         {:ok, session, session_cookie} <-
           Sessions.create(hosted_identity, device_context) do
      {:ok,
       %{
         account: account,
         hosted_identity: hosted_identity,
         personal_workspace: personal_workspace,
         session: session,
         session_cookie: session_cookie
       }}
    else
      _unavailable -> @failure
    end
  end

  def restore(_unverified_or_missing_method, _device_context), do: @failure

  @doc """
  Denies verified-email replacement without fresh proof of both the current and
  proposed email. The deferred two-proof flow is the only future mutation seam.
  """
  @spec change_verified_email(term(), term()) :: {:error, :fresh_email_proofs_required}
  def change_verified_email(_identity_or_session, _requested_email) do
    {:error, :fresh_email_proofs_required}
  end
end
