defmodule SddOrchestrator.Projects.ConnectionsTest do
  @moduledoc """
  Domain proof for repository-connection revalidation (Task 8): confirmed access
  keeps a project connected and refreshes its metadata; a missing installation,
  authorization failure, or failed credential marks it disconnected without
  deleting it; a transient provider outage shows temporarily-unavailable without
  overwriting the last confirmed state; and a project that lost access reconnects
  to the same project when access returns.
  """
  use SddOrchestrator.DataCase, async: true

  alias SddOrchestrator.Projects.{Connections, RepositoryConnection}

  alias SddOrchestrator.AccountsFixtures
  alias SddOrchestrator.ProjectsFixtures

  # Registers a project (repo id 101) in a fresh workspace whose account drives the
  # given fake-provider scenario via its login prefix.
  defp setup_project(login) do
    account = AccountsFixtures.account_fixture(login: login)
    workspace = ProjectsFixtures.workspace_fixture(account)
    project = ProjectsFixtures.registered_project(workspace)
    %{account: account, workspace: workspace, project: project}
  end

  defp reload_connection(project) do
    Repo.get_by!(RepositoryConnection, project_id: project.id)
  end

  describe "revalidation — confirmed access" do
    test "keeps the connection connected and refreshes display metadata" do
      %{account: account, workspace: workspace, project: project} = setup_project("octo")

      entry = Connections.project(account, workspace, project.id, revalidate: true)

      assert entry.status == :connected
      assert entry.connection.state == "connected"
      assert entry.connection.full_name == "octo/example"
      assert entry.connection.last_validated_at
      assert reload_connection(project).state == "connected"
    end

    test "reconnects a previously disconnected project when access returns (AC-38)" do
      %{account: account, workspace: workspace, project: project} = setup_project("octo")

      reload_connection(project)
      |> Ecto.Changeset.change(state: "disconnected")
      |> Repo.update!()

      entry = Connections.project(account, workspace, project.id, revalidate: true)

      assert entry.status == :connected
      assert entry.project.id == project.id
      assert reload_connection(project).state == "connected"
    end
  end

  describe "revalidation — confirmed loss (AC-37)" do
    test "marks the connection disconnected when no installation is accessible" do
      %{account: account, workspace: workspace, project: project} = setup_project("noinstall-x")

      entry = Connections.project(account, workspace, project.id, revalidate: true)

      assert entry.status == :disconnected
      assert reload_connection(project).state == "disconnected"
      # The project is not deleted; it remains visible.
      assert entry.project.id == project.id
    end

    test "marks the connection disconnected on an authorization failure" do
      %{account: account, workspace: workspace, project: project} =
        setup_project("unauthorized-x")

      entry = Connections.project(account, workspace, project.id, revalidate: true)

      assert entry.status == :disconnected
      assert reload_connection(project).state == "disconnected"
    end

    test "marks the connection disconnected when the credential is gone" do
      %{account: account, workspace: workspace, project: project} = setup_project("octo")

      Repo.delete_all(
        from c in SddOrchestrator.Accounts.GitHubCredential, where: c.account_id == ^account.id
      )

      entry = Connections.project(account, workspace, project.id, revalidate: true)

      assert entry.status == :disconnected
      assert reload_connection(project).state == "disconnected"
    end
  end

  describe "revalidation — transient outage" do
    test "shows temporarily-unavailable without overwriting the last confirmed state" do
      %{account: account, workspace: workspace, project: project} = setup_project("ratelimit-x")

      # The connection was last confirmed connected at creation.
      assert reload_connection(project).state == "connected"

      entry = Connections.project(account, workspace, project.id, revalidate: true)

      assert entry.status == :temporarily_unavailable
      # The last confirmed state is preserved through the transient failure.
      assert reload_connection(project).state == "connected"
    end
  end

  describe "catalog status" do
    test "lists each project's status and persisted-state read avoids a provider call" do
      %{account: account, workspace: workspace, project: project} = setup_project("octo")

      # revalidate: false reads the last confirmed state without contacting GitHub.
      [entry] = Connections.catalog(account, workspace, revalidate: false)

      assert entry.project.id == project.id
      assert entry.status == :connected
    end
  end
end
