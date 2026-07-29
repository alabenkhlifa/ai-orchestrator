defmodule SddOrchestrator.Participation.ProjectNotifications do
  @moduledoc """
  Projects participation lifecycle events into in-product notifications.

  Recipients are resolved from current project state at projection time and each
  event uses the shared account-level store's event, subject, version, and
  recipient key, so replaying a lifecycle sweep creates no duplicate. Bodies
  name the project label and the action only; anything more specific stays
  behind the participation link, which is authorized on its own.
  """

  alias SddOrchestrator.Accounts.HostedIdentity
  alias SddOrchestrator.Notifications
  alias SddOrchestrator.Participation
  alias SddOrchestrator.Participation.{ProjectInvitation, ProjectMemberProfile}
  alias SddOrchestrator.Projects.Project

  @doc """
  Tells the project owner that one pending invitation expired.

  The invited person receives no project notification: they never had project
  access, so an in-product record would disclose the project to them.
  """
  @spec invitation_expired(Project.t(), ProjectInvitation.t()) ::
          {:ok, Notifications.AccountNotification.t()} | {:error, term()}
  def invitation_expired(%Project{} = project, %ProjectInvitation{} = invitation) do
    with {:ok, owner} <- Participation.owner(project) do
      Notifications.deliver(%{
        account_id: owner.account_id,
        event_type: "participation.invitation_expired",
        subject_ref: invitation.id,
        event_version: invitation.credential_version,
        title: "An invitation expired",
        body: "One invitation to #{project.name} expired before it was accepted.",
        project_label: project.name,
        link_path: participation_path(project),
        occurred_at: invitation.terminal_at
      })
    end
  end

  @doc "The event that confirms accepted participation to the new participant."
  @spec acceptance_participant_event(Project.t(), ProjectMemberProfile.t(), HostedIdentity.t()) ::
          map()
  def acceptance_participant_event(
        %Project{} = project,
        %ProjectMemberProfile{} = profile,
        identity
      ) do
    %{
      account_id: identity.account_id,
      event_type: "participation.joined",
      subject_ref: profile.id,
      event_version: 1,
      title: "You joined #{project.name}",
      body: "You are now on #{project.name} as #{profile.display_name}.",
      project_label: project.name,
      actor_label: profile.display_name,
      link_path: project_path(project)
    }
  end

  @doc "The event that tells the owner one invitation was accepted."
  @spec acceptance_owner_event(Project.t(), ProjectMemberProfile.t(), map()) :: map()
  def acceptance_owner_event(%Project{} = project, %ProjectMemberProfile{} = profile, owner) do
    %{
      account_id: owner.account_id,
      event_type: "participation.participant_joined",
      subject_ref: profile.id,
      event_version: 1,
      title: "Someone joined #{project.name}",
      body: "#{profile.display_name} accepted an invitation to #{project.name}.",
      project_label: project.name,
      actor_label: profile.display_name,
      link_path: participation_path(project)
    }
  end

  @doc "The event that tells the owner one invitation was declined."
  @spec decline_owner_event(Project.t(), ProjectInvitation.t(), map()) :: map()
  def decline_owner_event(%Project{} = project, %ProjectInvitation{} = invitation, owner) do
    %{
      account_id: owner.account_id,
      event_type: "participation.invitation_declined",
      subject_ref: invitation.id,
      event_version: invitation.credential_version,
      title: "An invitation was declined",
      body: "One invitation to #{project.name} was declined.",
      project_label: project.name,
      link_path: participation_path(project),
      occurred_at: invitation.terminal_at
    }
  end

  @doc """
  The event that tells a removed person at their account boundary.

  The link stays at the account level because project access has already ended;
  it restores nothing.
  """
  @spec removal_event(Project.t(), map()) :: map()
  def removal_event(%Project{} = project, revocation) do
    %{
      account_id: revocation.former_account_id,
      event_type: "participation.removed",
      subject_ref: revocation.id,
      event_version: revocation.contract_version,
      title: "You were removed from #{project.name}",
      body: "You no longer have access to #{project.name}. Your account is unchanged.",
      project_label: project.name,
      link_path: "/hosted/access/sessions",
      occurred_at: revocation.occurred_at
    }
  end

  @doc "The event that tells the owner one participant left."
  @spec leave_event(Project.t(), map()) :: map()
  def leave_event(%Project{} = project, revocation) do
    %{
      account_id: revocation.owner_account_id,
      event_type: "participation.left",
      subject_ref: revocation.id,
      event_version: revocation.contract_version,
      title: "Someone left #{project.name}",
      body: "#{revocation.last_display_name || "A participant"} left #{project.name}.",
      project_label: project.name,
      actor_label: revocation.last_display_name,
      link_path: participation_path(project),
      occurred_at: revocation.occurred_at
    }
  end

  @spec participation_path(Project.t()) :: String.t()
  def participation_path(%Project{id: id}), do: "/projects/#{id}/participation"

  @spec project_path(Project.t()) :: String.t()
  def project_path(%Project{id: id}), do: "/projects/#{id}"
end
