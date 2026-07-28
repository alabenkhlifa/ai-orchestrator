defmodule SddOrchestrator.IdentityLinking.PreflightTest do
  @moduledoc """
  Proofs for the non-mutating merge preflight: overlapping project history is not
  a conflict, case-insensitive name collisions and canonical repository collisions
  are, and preflight never mutates state.
  """
  use SddOrchestrator.DataCase, async: true

  alias SddOrchestrator.IdentityLinking
  alias SddOrchestrator.IdentityLinking.Preflight
  alias SddOrchestrator.Projects.{Project, RepositoryConnection}

  import SddOrchestrator.AccountsFixtures
  import SddOrchestrator.HostedAccessFixtures
  import SddOrchestrator.ProjectsFixtures

  defp merge_scenario(email \\ "owner@example.com") do
    absorbed = account_fixture()
    %{personal_workspace: surviving_ws} = hosted_identity_fixture(email: email)
    {:ok, attempt} = IdentityLinking.start_merge_attempt(absorbed, email)
    absorbed_ws = workspace_fixture(absorbed)
    %{attempt: attempt, surviving_ws: surviving_ws, absorbed_ws: absorbed_ws}
  end

  test "projects on both identities with no overlap are normal history, not a conflict" do
    %{attempt: attempt, surviving_ws: sw, absorbed_ws: aw} = merge_scenario()
    project_fixture(sw, name: "Surviving Project")
    project_fixture(aw, name: "Absorbed Project")

    preflight = IdentityLinking.preflight(attempt)

    assert Preflight.clear?(preflight)
    assert preflight.name_conflicts == []
    assert preflight.repository_conflicts == []
  end

  test "a case-insensitive project-name collision is a conflict" do
    %{attempt: attempt, surviving_ws: sw, absorbed_ws: aw} = merge_scenario()
    project_fixture(sw, name: "Roadmap")
    project_fixture(aw, name: "roadmap")

    preflight = IdentityLinking.preflight(attempt)

    refute Preflight.clear?(preflight)
    assert [%{name_key: "roadmap"}] = preflight.name_conflicts
    assert preflight.repository_conflicts == []
  end

  test "a shared canonical repository is a conflict" do
    %{attempt: attempt, surviving_ws: sw, absorbed_ws: aw} = merge_scenario()
    registered_project(sw, repository: repository_metadata(id: 500, name: "shared"), name: "Ours")

    registered_project(aw,
      repository: repository_metadata(id: 500, name: "shared"),
      name: "Theirs"
    )

    preflight = IdentityLinking.preflight(attempt)

    refute Preflight.clear?(preflight)
    assert [%{provider: "github", provider_repository_id: 500}] = preflight.repository_conflicts
    assert preflight.name_conflicts == []
  end

  test "preflight and abort mutate no project or connection state" do
    %{attempt: attempt, surviving_ws: sw, absorbed_ws: aw} = merge_scenario()
    project_fixture(sw, name: "Roadmap")
    project_fixture(aw, name: "roadmap")

    before = {Repo.aggregate(Project, :count), Repo.aggregate(RepositoryConnection, :count)}

    _ = IdentityLinking.preflight(attempt)
    {:ok, _} = IdentityLinking.abort_merge_attempt(attempt)

    assert {Repo.aggregate(Project, :count), Repo.aggregate(RepositoryConnection, :count)} ==
             before
  end
end
