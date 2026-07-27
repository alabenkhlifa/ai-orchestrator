defmodule SddOrchestrator.HostedAccess do
  @moduledoc """
  Passwordless hosted-identity and workspace boundary.

  Identity restoration accepts only successfully verified email addresses.
  Magic-link requests remain account-neutral; token verification and
  hosted-session lifecycle are implemented by later Slice 03 tasks.
  """

  alias Ecto.Multi

  alias SddOrchestrator.Accounts.{
    Account,
    ExternalIdentity,
    HostedIdentity,
    PersonalWorkspace,
    Workspace
  }

  alias SddOrchestrator.Repo

  @doc """
  Requests a passwordless sign-in link without revealing validation,
  throttling, delivery, or account-existence state.
  """
  @spec request_magic_link(term(), map() | keyword()) :: {:ok, %{status: :accepted}}
  defdelegate request_magic_link(email, context \\ %{}),
    to: SddOrchestrator.HostedAccess.MagicLinks,
    as: :request

  @doc """
  Atomically verifies one attempt-bound magic-link token and creates its first
  hosted session. Every failure returns the same safe result.
  """
  @spec verify_magic_link(term(), term(), map() | keyword()) ::
          {:ok, SddOrchestrator.HostedAccess.Verification.verification_result()}
          | {:error, :invalid_or_expired}
  defdelegate verify_magic_link(attempt_id, raw_token, device_context \\ %{}),
    to: SddOrchestrator.HostedAccess.Verification,
    as: :verify

  @type identity_result :: %{
          account: Account.t(),
          external_identity: ExternalIdentity.t(),
          hosted_identity: HostedIdentity.t(),
          personal_workspace: PersonalWorkspace.t()
        }

  @doc """
  Restores the stable hosted identity for a verified email, or creates its
  account and personal workspace atomically on first verification.

  Case-only variants share one comparison key. A successful later verification
  may refresh the preserved delivery/display spelling without changing any
  stable identifier.
  """
  @spec restore_or_create_identity(String.t()) ::
          {:ok, identity_result()} | {:error, :invalid_email | Ecto.Changeset.t()}
  def restore_or_create_identity(email) do
    with {:ok, email_attrs} <- ExternalIdentity.normalize_email(email) do
      case get_identity_by_key(email_attrs.subject_key) do
        {:ok, result} -> refresh_verified_spelling(result, email_attrs)
        :error -> create_identity(email_attrs)
      end
    end
  end

  @doc "Returns the hosted identity for an email without creating any state."
  @spec get_identity_by_email(String.t()) :: {:ok, identity_result()} | :error
  def get_identity_by_email(email) do
    case ExternalIdentity.normalize_email(email) do
      {:ok, %{subject_key: key}} -> get_identity_by_key(key)
      {:error, :invalid_email} -> :error
    end
  end

  defp create_identity(email_attrs) do
    workspace_id = Ecto.UUID.generate()
    verified_at = now()

    Multi.new()
    |> Multi.insert(:account, Account.changeset(%Account{}, %{state: :active}))
    |> Multi.insert(:hosted_identity, fn %{account: account} ->
      HostedIdentity.changeset(%HostedIdentity{}, %{account_id: account.id})
    end)
    |> Multi.insert(:external_identity, fn %{hosted_identity: identity} ->
      ExternalIdentity.changeset(
        %ExternalIdentity{},
        Map.merge(email_attrs, %{
          provider: "email",
          hosted_identity_id: identity.id,
          verified_at: verified_at
        })
      )
    end)
    |> Multi.insert(
      :workspace,
      Workspace.changeset(%Workspace{id: workspace_id}, %{kind: "hosted"})
    )
    |> Multi.insert(:personal_workspace, fn %{account: account, workspace: workspace} ->
      PersonalWorkspace.changeset(%PersonalWorkspace{}, %{
        id: workspace.id,
        account_id: account.id
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, changes} ->
        {:ok, result_from_changes(changes)}

      {:error, _step, reason, _changes} ->
        restore_after_conflict(email_attrs, reason)
    end
  end

  defp restore_after_conflict(email_attrs, reason) do
    case get_identity_by_key(email_attrs.subject_key) do
      {:ok, result} -> refresh_verified_spelling(result, email_attrs)
      :error -> {:error, reason}
    end
  end

  defp refresh_verified_spelling(result, email_attrs) do
    result.external_identity
    |> ExternalIdentity.changeset(
      Map.merge(email_attrs, %{
        provider: "email",
        hosted_identity_id: result.hosted_identity.id,
        verified_at: now()
      })
    )
    |> Repo.update()
    |> case do
      {:ok, external_identity} -> {:ok, %{result | external_identity: external_identity}}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp get_identity_by_key(subject_key) do
    case Repo.get_by(ExternalIdentity, provider: "email", subject_key: subject_key) do
      nil ->
        :error

      external_identity ->
        hosted_identity =
          external_identity
          |> Repo.preload(hosted_identity: :account)
          |> Map.fetch!(:hosted_identity)

        personal_workspace =
          PersonalWorkspace
          |> Repo.get_by!(account_id: hosted_identity.account.id)
          |> Repo.preload(:workspace)

        {:ok,
         %{
           account: hosted_identity.account,
           external_identity: external_identity,
           hosted_identity: hosted_identity,
           personal_workspace: personal_workspace
         }}
    end
  end

  defp result_from_changes(changes) do
    %{
      account: changes.account,
      external_identity: changes.external_identity,
      hosted_identity: changes.hosted_identity,
      personal_workspace: Repo.preload(changes.personal_workspace, :workspace)
    }
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
