defmodule SddOrchestrator.Projects.Connections do
  @moduledoc """
  Repository-connection state and revalidation (Task 8).

  A project stays visible when GitHub access changes; only its connection state
  moves. Revalidation re-reads the authenticated user's access when the catalog or
  dashboard loads (and on `Check again`) and resolves each connection to a display
  status:

    * `:connected` — the repository is still accessible; the persisted state and
      display metadata are refreshed.
    * `:disconnected` — access is confirmed lost (no installation, a pending or
      unapproved request, an authorization failure, or a failed token refresh);
      the persisted state becomes `disconnected` without deleting the project.
    * `:temporarily_unavailable` — a transient provider outage (rate limit, org
      policy, or provider failure). This is display-only: the last confirmed state
      is never overwritten, so a blip does not read as access loss.

  The access token stays inside this module and the provider adapter; the entries
  returned to the web layer carry only project and connection metadata, never a
  credential.
  """
  import Ecto.Query

  alias SddOrchestrator.Accounts
  alias SddOrchestrator.Accounts.{Account, PersonalWorkspace}
  alias SddOrchestrator.GitHubIntegration
  alias SddOrchestrator.Projects.{Project, RepositoryConnection}
  alias SddOrchestrator.Repo

  @type status :: :connected | :disconnected | :temporarily_unavailable
  @type entry :: %{
          project: Project.t(),
          connection: RepositoryConnection.t() | nil,
          status: status()
        }

  @doc """
  The workspace catalog with each project's connection status.

  With `revalidate: true` (the connected mount) access is re-read and connected or
  disconnected transitions are persisted; with `revalidate: false` (the initial
  paint) the last confirmed persisted state is shown without a provider call.
  """
  @spec catalog(Account.t(), PersonalWorkspace.t(), keyword()) :: [entry()]
  def catalog(%Account{} = account, %PersonalWorkspace{} = workspace, opts \\ []) do
    projects =
      Repo.all(
        from p in Project,
          where: p.workspace_id == ^workspace.id,
          order_by: [asc: p.name, asc: p.id],
          preload: [:repository_connection]
      )

    connections = for p <- projects, c = p.repository_connection, do: c
    statuses = statuses(account, connections, opts)

    Enum.map(projects, &to_entry(&1, statuses))
  end

  @doc """
  One project with its connection status, scoped to the workspace, or nil for a
  missing, malformed, or cross-workspace id. `revalidate:` behaves as in `catalog/3`.
  """
  @spec project(Account.t(), PersonalWorkspace.t(), String.t(), keyword()) :: entry() | nil
  def project(%Account{} = account, %PersonalWorkspace{} = workspace, project_id, opts \\ [])
      when is_binary(project_id) do
    with {:ok, uuid} <- Ecto.UUID.cast(project_id),
         %Project{} = project <-
           Repo.one(
             from p in Project,
               where: p.id == ^uuid and p.workspace_id == ^workspace.id,
               preload: [:repository_connection, :hosted_storage]
           ) do
      statuses = statuses(account, List.wrap(project.repository_connection), opts)
      to_entry(project, statuses)
    else
      _ -> nil
    end
  end

  # Builds the connection-id => {connection, status} map, either from a fresh
  # revalidation or from the persisted state.
  defp statuses(account, connections, opts) do
    if Keyword.get(opts, :revalidate, true),
      do: revalidate(account, connections),
      else: persisted(connections)
  end

  defp persisted(connections) do
    Map.new(connections, fn conn -> {conn.id, {conn, persisted_status(conn.state)}} end)
  end

  defp persisted_status("connected"), do: :connected
  defp persisted_status(_), do: :disconnected

  defp revalidate(_account, []), do: %{}

  defp revalidate(account, connections) do
    outcome = access_outcome(account)
    Map.new(connections, fn conn -> {conn.id, apply_outcome(conn, outcome)} end)
  end

  # Resolves the account's current repository access once, so every connection is
  # judged against a single read.
  defp access_outcome(%Account{id: account_id}) do
    case Accounts.valid_access_token(account_id) do
      {:error, _reason} ->
        # A failed refresh or missing credential is confirmed access loss.
        :disconnected

      {:ok, token} ->
        identity = Accounts.get_github_identity(account_id)
        github_user_id = identity && identity.github_user_id

        case GitHubIntegration.check_repository_access(token, github_user_id) do
          {:ok, :granted, installations} -> accessible_outcome(token, installations)
          {:ok, :pending, _org} -> :disconnected
          {:ok, :none} -> :disconnected
          {:error, reason} -> error_outcome(reason)
        end
    end
  end

  defp accessible_outcome(token, installations) do
    case GitHubIntegration.list_accessible_repositories(token, installations) do
      {:ok, repos} -> {:accessible, index_by_id(repos)}
      {:error, reason} -> error_outcome(reason)
    end
  end

  # An authorization failure is confirmed loss; a rate limit, org policy block, or
  # provider outage is transient and must not overwrite the last confirmed state.
  defp error_outcome(:unauthorized), do: :disconnected
  defp error_outcome(_transient), do: :unavailable

  defp apply_outcome(conn, :disconnected),
    do: {persist_state(conn, "disconnected"), :disconnected}

  defp apply_outcome(conn, :unavailable), do: {conn, :temporarily_unavailable}

  defp apply_outcome(conn, {:accessible, by_id}) do
    case Map.get(by_id, conn.provider_repository_id) do
      nil -> {persist_state(conn, "disconnected"), :disconnected}
      repo -> {persist_connected(conn, repo), :connected}
    end
  end

  defp persist_state(conn, state) do
    conn
    |> RepositoryConnection.status_changeset(%{state: state, last_validated_at: now()})
    |> Repo.update!()
  end

  defp persist_connected(conn, repo) do
    conn
    |> RepositoryConnection.status_changeset(%{
      state: "connected",
      last_validated_at: now(),
      owner: repo.owner,
      name: repo.name,
      full_name: repo.full_name,
      html_url: repo.html_url,
      visibility: repo.visibility,
      private: repo.private,
      organization: repo.organization
    })
    |> Repo.update!()
  end

  defp index_by_id(repos), do: Map.new(repos, fn repo -> {repo.id, repo} end)

  defp to_entry(project, statuses) do
    case project.repository_connection do
      %RepositoryConnection{id: id} ->
        {connection, status} = Map.fetch!(statuses, id)
        %{project: project, connection: connection, status: status}

      _ ->
        %{project: project, connection: nil, status: :disconnected}
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
