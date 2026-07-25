defmodule SddOrchestrator.ProjectsFixtures do
  @moduledoc "Test fixtures for personal workspaces, projects, and onboarding attempts."

  alias SddOrchestrator.Accounts
  alias SddOrchestrator.Accounts.Account
  alias SddOrchestrator.Projects.Project
  alias SddOrchestrator.Repo

  @doc "Restores (or creates) the personal workspace for an account."
  def workspace_fixture(%Account{} = account) do
    Accounts.get_or_create_personal_workspace(account)
  end

  @doc "Creates a project in the given workspace."
  def project_fixture(workspace, attrs \\ %{}) do
    name = attrs[:name] || "project-#{System.unique_integer([:positive])}"

    {:ok, project} =
      %Project{}
      |> Project.changeset(%{name: name, workspace_id: workspace.id})
      |> Repo.insert()

    project
  end
end
