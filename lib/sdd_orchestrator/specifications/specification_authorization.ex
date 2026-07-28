defmodule SddOrchestrator.Specifications.SpecificationAuthorization do
  @moduledoc """
  Fail-closed authorization seam for specification-store adapters.

  The hosted implementation begins with project ownership through the current
  personal workspace. Later participant authorization can extend this seam
  without changing specification identities or persistence.
  """

  alias SddOrchestrator.Accounts.PersonalWorkspace
  alias SddOrchestrator.Projects
  alias SddOrchestrator.Projects.Project
  alias SddOrchestrator.Repo

  @spec hosted_project(PersonalWorkspace.t(), String.t()) ::
          {:ok, SddOrchestrator.Projects.Project.t()} | {:error, :not_found}
  def hosted_project(authority, project_id) do
    hosted_project(authority, project_id, nil)
  end

  @spec hosted_project(term(), String.t(), module() | nil) ::
          {:ok, Project.t()} | {:error, :not_found}
  def hosted_project(%PersonalWorkspace{} = workspace, project_id, policy)
      when is_binary(project_id) do
    case Projects.get_project(workspace, project_id) do
      nil -> authorize_with_policy(policy, workspace, project_id)
      project -> {:ok, project}
    end
  end

  def hosted_project(authority, project_id, policy) when is_binary(project_id) do
    authorize_with_policy(policy, authority, project_id)
  end

  def hosted_project(_authority, _project_id, _policy), do: {:error, :not_found}

  defp authorize_with_policy(nil, _authority, _project_id), do: {:error, :not_found}

  defp authorize_with_policy(policy, authority, project_id) when is_atom(policy) do
    with :ok <- policy.authorize_project(authority, project_id),
         %Project{storage_mode: "hosted"} = project <- Repo.get(Project, project_id) do
      {:ok, project}
    else
      _reason -> {:error, :not_found}
    end
  end
end
