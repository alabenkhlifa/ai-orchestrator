defmodule SddOrchestrator.Privacy.Rights do
  @moduledoc """
  Verified data-subject-rights handling for Slice 01 (operator workflow).

  This slice serves rights requests through an authenticated operator workflow
  rather than a self-service screen. Two operations are implemented end to end:

    * `export_account/1` — access and portability: gathers the account's identity,
      workspace, projects, repository connections, and session metadata into a
      structured, credential-free map.
    * `erase_account/1` — erasure: atomically deletes the hosted workspace root
      and account, cascading to identity, credentials, sessions, the personal
      profile, projects, repository connections, hosted storage, and onboarding
      attempts, reaching every active copy.

  Retained copies outside the primary store (encrypted backups) are expired by the
  deployment's backup lifecycle, recorded in the deployment privacy profile.
  Transient GitHub authorization attempts carry no account id and are removed by
  time-based retention. Exports never include access or refresh tokens, PKCE
  verifiers, or session digests.
  """
  import Ecto.Query

  alias Ecto.Multi

  alias SddOrchestrator.Accounts.{
    Account,
    ApplicationSession,
    GitHubIdentity,
    PersonalWorkspace,
    Workspace
  }

  alias SddOrchestrator.Projects.Project
  alias SddOrchestrator.Repo

  @doc """
  Assembles a credential-free export of everything the deployment holds for an
  account. Returns `{:error, :not_found}` for an unknown account.
  """
  @spec export_account(String.t()) :: {:ok, map()} | {:error, :not_found}
  def export_account(account_id) when is_binary(account_id) do
    case Repo.get(Account, account_id) do
      nil ->
        {:error, :not_found}

      %Account{} = account ->
        {:ok,
         %{
           account: %{id: account.id, state: account.state},
           github_identity: export_identity(account_id),
           projects: export_projects(account_id),
           sessions: export_sessions(account_id)
         }}
    end
  end

  @doc """
  Erases an account, its hosted workspace root, and every record that cascades
  from them. Returns
  `{:error, :not_found}` for an unknown account.
  """
  @spec erase_account(String.t()) :: {:ok, %{account_id: String.t()}} | {:error, :not_found}
  def erase_account(account_id) when is_binary(account_id) do
    case Repo.get(Account, account_id) do
      nil ->
        {:error, :not_found}

      %Account{} = account ->
        workspace = Repo.get_by(PersonalWorkspace, account_id: account.id)

        Multi.new()
        |> maybe_delete_workspace(workspace)
        |> Multi.delete(:account, account)
        |> Repo.transaction()
        |> case do
          {:ok, _changes} -> {:ok, %{account_id: account.id}}
          {:error, _step, _reason, _changes} -> {:error, :not_found}
        end
    end
  end

  defp maybe_delete_workspace(multi, nil), do: multi

  defp maybe_delete_workspace(multi, %PersonalWorkspace{id: workspace_id}) do
    Multi.delete_all(multi, :workspace, from(w in Workspace, where: w.id == ^workspace_id))
  end

  defp export_identity(account_id) do
    case Repo.one(from i in GitHubIdentity, where: i.account_id == ^account_id) do
      nil ->
        nil

      identity ->
        %{
          github_user_id: identity.github_user_id,
          login: identity.login,
          avatar_url: identity.avatar_url
        }
    end
  end

  defp export_projects(account_id) do
    workspace = Repo.one(from w in PersonalWorkspace, where: w.account_id == ^account_id)

    case workspace do
      nil ->
        []

      %PersonalWorkspace{id: workspace_id} ->
        from(p in Project,
          where: p.workspace_id == ^workspace_id,
          order_by: [asc: p.name],
          preload: [:repository_connection]
        )
        |> Repo.all()
        |> Enum.map(&export_project/1)
    end
  end

  defp export_project(project) do
    %{
      id: project.id,
      name: project.name,
      storage_mode: project.storage_mode,
      repository: export_connection(project.repository_connection)
    }
  end

  defp export_connection(nil), do: nil

  defp export_connection(connection) do
    %{
      provider: connection.provider,
      provider_repository_id: connection.provider_repository_id,
      full_name: connection.full_name,
      visibility: connection.visibility,
      state: connection.state
    }
  end

  defp export_sessions(account_id) do
    from(s in ApplicationSession,
      where: s.account_id == ^account_id,
      order_by: [desc: s.inserted_at]
    )
    |> Repo.all()
    |> Enum.map(fn session ->
      %{
        id: session.id,
        last_used_at: session.last_used_at,
        idle_expires_at: session.idle_expires_at,
        absolute_expires_at: session.absolute_expires_at,
        revoked_at: session.revoked_at
      }
    end)
  end
end
