defmodule SddOrchestrator.ProjectsFixtures do
  @moduledoc "Test fixtures for personal workspaces, projects, and onboarding attempts."

  alias SddOrchestrator.Accounts
  alias SddOrchestrator.Accounts.Account
  alias SddOrchestrator.Projects
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

  @doc "A representative selected-repository metadata map."
  def repository_metadata(attrs \\ %{}) do
    Map.merge(
      %{
        id: 101,
        owner: "octo",
        name: "example",
        full_name: "octo/example",
        private: false,
        visibility: "public",
        html_url: "https://github.com/octo/example",
        organization: nil
      },
      Map.new(attrs)
    )
  end

  @doc "Starts an onboarding attempt with a repository already selected."
  def attempt_with_repository(workspace, repository \\ repository_metadata()) do
    {:ok, attempt} = Projects.start_onboarding_attempt(workspace)
    {:ok, attempt} = Projects.select_repository(workspace, attempt.id, repository)
    attempt
  end

  @doc """
  Starts an onboarding attempt ready for confirmation: a repository is selected and
  a storage mode chosen (hosted by default), so `register_project/3` can run.
  """
  def attempt_ready(workspace, opts \\ []) do
    repository = Keyword.get(opts, :repository, repository_metadata())
    mode = Keyword.get(opts, :storage_mode, "hosted")

    attempt = attempt_with_repository(workspace, repository)
    {:ok, attempt} = Projects.select_storage_mode(workspace, attempt.id, mode)
    attempt
  end

  @doc "Registers a project in a workspace through the real registration transaction."
  def registered_project(workspace, opts \\ []) do
    attempt = attempt_ready(workspace, opts)
    {:ok, project} = Projects.register_project(workspace, attempt, Keyword.take(opts, [:name]))
    project
  end
end
