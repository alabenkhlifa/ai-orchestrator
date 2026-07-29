defmodule SddOrchestrator.Participation.ProjectNotifications do
  @moduledoc """
  Projects participation lifecycle events into in-product notifications.

  Recipients are resolved from current project state at projection time and each
  event uses the shared account-level store's event, subject, version, and
  recipient key, so replaying a lifecycle sweep creates no duplicate. Bodies
  name the project label and the action only; anything more specific stays
  behind the participation link, which is authorized on its own.
  """

  alias SddOrchestrator.Notifications
  alias SddOrchestrator.Participation
  alias SddOrchestrator.Participation.ProjectInvitation
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

  @spec participation_path(Project.t()) :: String.t()
  def participation_path(%Project{id: id}), do: "/projects/#{id}/participation"
end
