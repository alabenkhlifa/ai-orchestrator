defmodule SddOrchestrator.Specifications.SpecificationAuthorization do
  @moduledoc """
  Fail-closed authorization seam for specification-store adapters.

  The hosted implementation begins with project ownership through the current
  personal workspace. Later participant authorization can extend this seam
  without changing specification identities or persistence.
  """

  alias SddOrchestrator.Accounts.PersonalWorkspace
  alias SddOrchestrator.Projects

  @spec hosted_project(PersonalWorkspace.t(), String.t()) ::
          {:ok, SddOrchestrator.Projects.Project.t()} | {:error, :not_found}
  def hosted_project(%PersonalWorkspace{} = workspace, project_id) when is_binary(project_id) do
    case Projects.get_project(workspace, project_id) do
      nil -> {:error, :not_found}
      project -> {:ok, project}
    end
  end

  def hosted_project(_authority, _project_id), do: {:error, :not_found}
end
