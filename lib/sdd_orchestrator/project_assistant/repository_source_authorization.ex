defmodule SddOrchestrator.ProjectAssistant.RepositorySourceAuthorization do
  @moduledoc """
  The acting-participant source-authorization boundary repository
  observation uses (AC-16).

  No per-participant repository or source authorization concept exists
  anywhere else in this codebase: `SddOrchestrator.Participation.Capabilities`
  explicitly excludes repository access from every project-participation
  capability, and design.md is explicit that "Project participation does not
  confer repository authority." This module is that boundary, and it answers
  a strictly narrower question than plain project participation: whether the
  acting participant may observe *this* project's connected repository right
  now, never whether they may read project content in general.

  Two authorities:

    * Hosted — the acting participant must first be a current project
      participant (`SddOrchestrator.Delivery.ParticipantGuard.authorize/2`,
      the same general membership check `ProjectContextAssembler.Hosted`
      already uses for a read surface outside `ProjectAssistant.Guard`'s own
      five actions). When the project has a GitHub `RepositoryConnection`,
      participation alone is not enough: the acting participant's *own*
      GitHub identity must currently have access to that exact connected
      repository, checked the same way `SddOrchestrator.Projects.Connections`
      already revalidates connection access — `Accounts.valid_access_token/1`
      resolves the acting participant's own stored credential (never the
      project owner's, never another participant's), and
      `GitHubIntegration.check_repository_access/2` plus
      `list_accessible_repositories/2` confirm the connected repository's
      exact numeric id is in what that credential can currently see. This is
      the concrete mechanism behind AC-16 and the requirements' own claim
      that "repository access may differ even when [participants] share
      access to the same hosted project." A hosted project with no GitHub
      connection (never one, or a local-worker-bound project) has no
      separate per-participant credential to differentiate on, so current
      participation is the full authorization answer; whether a worker is
      actually reachable to serve the request is a separate, later check
      (`RepositoryWorkerAvailability`), not this module's job.
    * Device — mirrors `ProjectAssistantStore.Device` and
      `ProjectContextAssembler.Device` exactly: a device-authoritative
      project has no hosted owner or participant
      (`SddOrchestrator.Participation.owner/1`), so there is only ever one
      possible acting identity, the device workspace that owns the local
      store, reverified fresh on every call.

  A denial never discloses which check failed for a project the participant
  cannot see at all: an absent, stale, removed, or cross-project identity
  collapses to `{:error, :unauthorized}`, the same fail-closed, no-existence
  disclosure every other project-assistant surface uses. A currently valid
  participant who lacks source access is a materially different, disclosed
  outcome the panel is expected to show (AC-16 itself), so that case returns
  the distinguishable `{:error, :source_denied}` instead.

  The request this module builds never carries a credential: it resolves and
  checks the acting participant's own token internally and returns only
  identity and repository *references* (`target()`), so a caller — and the
  read-only worker request built from it — cannot substitute another
  participant's, the owner's, or the application's credential even by
  accident.
  """

  alias SddOrchestrator.Accounts
  alias SddOrchestrator.Accounts.{DeviceWorkspace, PersonalWorkspace}
  alias SddOrchestrator.Delivery.ParticipantGuard
  alias SddOrchestrator.Devices
  alias SddOrchestrator.GitHubIntegration
  alias SddOrchestrator.Projects
  alias SddOrchestrator.Projects.RepositoryConnection

  @type authority :: PersonalWorkspace.t() | DeviceWorkspace.t()
  @type actor :: ParticipantGuard.actor()
  @type target :: %{
          project_id: Ecto.UUID.t(),
          repository_provider: String.t() | nil,
          repository_ref: String.t() | nil,
          actor_ref: String.t()
        }

  @doc """
  Answers whether the acting participant may observe this project's
  connected repository right now.

  Returns `{:ok, target}` with only opaque identity and repository
  references — never a credential, another participant's grant, or account
  diagnostics.
  """
  @spec authorize(authority(), String.t(), actor()) ::
          {:ok, target()} | {:error, :unauthorized | :source_denied}
  def authorize(%PersonalWorkspace{} = authority, project_id, actor) do
    with {:ok, member} <- ParticipantGuard.authorize(project_id, actor),
         {:ok, project} <- fetch_project(authority, project_id) do
      authorize_hosted_source(project, member)
    else
      _denied -> {:error, :unauthorized}
    end
  rescue
    Ecto.Query.CastError -> {:error, :unauthorized}
  end

  def authorize(%DeviceWorkspace{id: authority_id}, project_id, _actor) do
    with {:ok, %DeviceWorkspace{id: ^authority_id}} <- Devices.get_workspace(),
         {:ok, %{storage_mode: "device"} = project} <- Devices.get_project(project_id) do
      {:ok, device_target(project, authority_id)}
    else
      _denied -> {:error, :unauthorized}
    end
  end

  def authorize(_authority, _project_id, _actor), do: {:error, :unauthorized}

  defp fetch_project(authority, project_id) do
    case Projects.get_project(authority, project_id) do
      nil -> {:error, :unauthorized}
      project -> {:ok, project}
    end
  end

  defp authorize_hosted_source(project, member) do
    case project.repository_connection do
      nil -> {:ok, hosted_target(project, member)}
      %RepositoryConnection{} = connection -> authorize_github_access(project, connection, member)
    end
  end

  defp authorize_github_access(project, connection, member) do
    with {:ok, token} <- Accounts.valid_access_token(member.account_id),
         github_user_id = own_github_user_id(member.account_id),
         {:ok, :granted, installations} <-
           GitHubIntegration.check_repository_access(token, github_user_id),
         {:ok, repos} <- GitHubIntegration.list_accessible_repositories(token, installations),
         true <- Enum.any?(repos, &(&1.id == connection.provider_repository_id)) do
      {:ok, hosted_target(project, member)}
    else
      _denied -> {:error, :source_denied}
    end
  end

  # Always the acting participant's *own* account — never the project
  # owner's or any other member's — so a hosted repository connection can
  # never be observed on borrowed access.
  defp own_github_user_id(account_id) do
    case Accounts.get_github_identity(account_id) do
      nil -> nil
      identity -> identity.github_user_id
    end
  end

  defp hosted_target(project, member) do
    %{
      project_id: project.id,
      repository_provider: project.repository_provider,
      repository_ref: project.canonical_repository_id,
      actor_ref: member.account_id
    }
  end

  defp device_target(project, authority_id) do
    %{
      project_id: project.id,
      repository_provider: Map.get(project, :repository_provider),
      repository_ref: Map.get(project, :repository_id),
      actor_ref: authority_id
    }
  end
end
