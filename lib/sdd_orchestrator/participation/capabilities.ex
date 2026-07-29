defmodule SddOrchestrator.Participation.Capabilities do
  @moduledoc """
  What one person may currently do in one project.

  Every decision re-reads current participation instead of consulting a
  long-lived cache, so removal and leave take effect on the next action. A
  participant receives the project content capabilities the workflow needs —
  specifications, feature content, comments, and run evidence — and nothing
  else: membership management, project deletion, storage and repository
  settings, and every credential stay outside this boundary.

  Credential access is denied to everyone here, including the owner. Repository,
  worker, agent, model-provider, invitation, and session secrets are held by
  their own boundaries and are never granted through participation.
  """

  alias SddOrchestrator.Participation
  alias SddOrchestrator.Projects.Project

  @content_capabilities ~w(
    read_project
    read_specifications
    edit_specifications
    read_feature_content
    edit_feature_content
    comment
    read_run_evidence
  )a

  @management_capabilities ~w(
    manage_participants
    delete_project
    change_storage_mode
    change_repository_connection
  )a

  @credential_capabilities ~w(
    read_provider_credentials
    read_worker_credentials
    read_agent_credentials
    read_invitation_credentials
    read_session_credentials
  )a

  @visible_project_fields ~w(id name storage_mode)a

  @type actor :: %{
          optional(:account_id) => Ecto.UUID.t() | nil,
          optional(:hosted_identity_id) => Ecto.UUID.t() | nil
        }

  @spec content_capabilities() :: [atom()]
  def content_capabilities, do: @content_capabilities

  @spec management_capabilities() :: [atom()]
  def management_capabilities, do: @management_capabilities

  @spec credential_capabilities() :: [atom()]
  def credential_capabilities, do: @credential_capabilities

  @spec all_capabilities() :: [atom()]
  def all_capabilities,
    do: @content_capabilities ++ @management_capabilities ++ @credential_capabilities

  @doc """
  Lists the capabilities one actor currently holds in one project.
  """
  @spec capabilities(Project.t() | Ecto.UUID.t(), actor()) :: [atom()]
  def capabilities(project, actor) do
    case role(project, actor) do
      {:ok, :owner} -> @content_capabilities ++ @management_capabilities
      {:ok, :participant} -> @content_capabilities
      {:error, :unauthorized} -> []
    end
  end

  @doc """
  Reports whether one actor may currently perform one capability.

  An unknown capability name is denied rather than ignored.
  """
  @spec can?(Project.t() | Ecto.UUID.t(), actor(), atom()) :: boolean()
  def can?(project, actor, capability) do
    capability in all_capabilities() and capability in capabilities(project, actor)
  end

  @doc """
  Returns the project fields a current member may read.

  Fields that are not part of the approved project-content boundary are absent
  rather than nulled, so a template cannot render them by accident.
  """
  @spec visible_project(Project.t(), actor()) :: {:ok, map()} | {:error, :unauthorized}
  def visible_project(%Project{} = project, actor) do
    if can?(project, actor, :read_project) do
      {:ok, Map.take(Map.from_struct(project), @visible_project_fields)}
    else
      {:error, :unauthorized}
    end
  end

  defp role(project, actor) do
    Participation.member_role(
      project,
      Map.get(actor, :account_id),
      Map.get(actor, :hosted_identity_id)
    )
  end
end
