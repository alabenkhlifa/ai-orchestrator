defmodule SddOrchestrator.ParticipationFixtures do
  @moduledoc "Test fixtures for hosted-project participation."

  alias SddOrchestrator.HostedAccessFixtures
  alias SddOrchestrator.Participation.{ProjectMemberProfile, ProjectParticipant}
  alias SddOrchestrator.ProjectsFixtures
  alias SddOrchestrator.Repo

  @doc """
  Creates one hosted project owned by a fresh passwordless identity.

  Returns the owner identity result together with its workspace and project.
  """
  def hosted_project_fixture(attrs \\ %{}) do
    attrs = Map.new(attrs)
    owner = HostedAccessFixtures.hosted_identity_fixture(Map.take(attrs, [:email]))

    project =
      ProjectsFixtures.project_fixture(owner.personal_workspace, Map.take(attrs, [:name]))

    %{
      owner: owner,
      account: owner.account,
      workspace: owner.personal_workspace,
      project: project
    }
  end

  @doc "Creates one active participant authorization for a hosted identity."
  def participant_fixture(project, hosted_identity, attrs \\ %{}) do
    %ProjectParticipant{}
    |> ProjectParticipant.activation_changeset(
      Map.merge(
        %{project_id: project.id, hosted_identity_id: hosted_identity.id},
        Map.new(attrs)
      )
    )
    |> Repo.insert!()
  end

  @doc "Creates one current project display profile for an account."
  def member_profile_fixture(project, account, attrs \\ %{}) do
    attrs = Map.new(attrs)

    %ProjectMemberProfile{}
    |> ProjectMemberProfile.changeset(%{
      project_id: project.id,
      account_id: account.id,
      role: Map.get(attrs, :role, "participant"),
      display_name: Map.get(attrs, :display_name, unique_display_name())
    })
    |> Repo.insert!()
  end

  @doc "Creates one additional hosted identity that is not yet a participant."
  def invited_identity_fixture(attrs \\ %{}) do
    HostedAccessFixtures.hosted_identity_fixture(attrs)
  end

  def unique_display_name(prefix \\ "Member"),
    do: "#{prefix} #{System.unique_integer([:positive])}"
end
