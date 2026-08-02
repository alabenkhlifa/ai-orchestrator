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

  @payload_fields %{
    "participation.invitation_expired" => [
      :account_id,
      :event_type,
      :subject_ref,
      :event_version,
      :title,
      :body,
      :project_label,
      :link_path,
      :occurred_at
    ],
    "participation.joined" => [
      :account_id,
      :event_type,
      :subject_ref,
      :event_version,
      :title,
      :body,
      :project_label,
      :actor_label,
      :link_path
    ],
    "participation.participant_joined" => [
      :account_id,
      :event_type,
      :subject_ref,
      :event_version,
      :title,
      :body,
      :project_label,
      :actor_label,
      :link_path
    ],
    "participation.invitation_declined" => [
      :account_id,
      :event_type,
      :subject_ref,
      :event_version,
      :title,
      :body,
      :project_label,
      :link_path,
      :occurred_at
    ],
    "participation.removed" => [
      :account_id,
      :event_type,
      :subject_ref,
      :event_version,
      :title,
      :body,
      :project_label,
      :link_path,
      :occurred_at
    ],
    "participation.left" => [
      :account_id,
      :event_type,
      :subject_ref,
      :event_version,
      :title,
      :body,
      :project_label,
      :actor_label,
      :link_path,
      :occurred_at
    ]
  }

  @project_links ~w(participation.joined)
  @participation_links ~w(
    participation.invitation_expired
    participation.participant_joined
    participation.invitation_declined
    participation.left
  )

  @doc "The exact persisted fields approved for one participation event."
  @spec payload_fields(String.t()) :: [atom()]
  def payload_fields(event_type), do: Map.get(@payload_fields, event_type, [])

  @doc "Validates the participation-specific field and safe-link allowlists."
  @spec validate_payload(map()) ::
          :ok
          | {:error, :unsupported_event | :unapproved_fields | :unapproved_content | :unsafe_link}
  def validate_payload(%{event_type: event_type, link_path: link_path} = payload)
      when is_binary(event_type) and is_binary(link_path) do
    case Map.fetch(@payload_fields, event_type) do
      :error ->
        {:error, :unsupported_event}

      {:ok, fields} ->
        cond do
          Enum.sort(Map.keys(payload)) != Enum.sort(fields) -> {:error, :unapproved_fields}
          not approved_content?(payload) -> {:error, :unapproved_content}
          not safe_link?(event_type, link_path) -> {:error, :unsafe_link}
          true -> :ok
        end
    end
  end

  def validate_payload(_payload), do: {:error, :unapproved_fields}

  @doc """
  Tells the project owner that one pending invitation expired.

  The invited person receives no project notification: they never had project
  access, so an in-product record would disclose the project to them.
  """
  @spec invitation_expired(Project.t(), ProjectInvitation.t()) ::
          {:ok, Notifications.AccountNotification.t()} | {:error, term()}
  def invitation_expired(%Project{} = project, %ProjectInvitation{} = invitation) do
    with {:ok, owner} <- Participation.owner(project) do
      project
      |> invitation_expired_event(invitation, owner)
      |> Notifications.deliver()
    end
  end

  @doc "The minimized event that reports an expired invitation to its project owner."
  @spec invitation_expired_event(Project.t(), ProjectInvitation.t(), map()) :: map()
  def invitation_expired_event(%Project{} = project, %ProjectInvitation{} = invitation, owner) do
    minimized_payload!(%{
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

  @doc "The event that confirms accepted participation to the new participant."
  @spec acceptance_participant_event(Project.t(), ProjectMemberProfile.t(), HostedIdentity.t()) ::
          map()
  def acceptance_participant_event(
        %Project{} = project,
        %ProjectMemberProfile{} = profile,
        identity
      ) do
    minimized_payload!(%{
      account_id: identity.account_id,
      event_type: "participation.joined",
      subject_ref: profile.id,
      event_version: 1,
      title: "You joined #{project.name}",
      body: "You are now on #{project.name} as #{profile.display_name}.",
      project_label: project.name,
      actor_label: profile.display_name,
      link_path: project_path(project)
    })
  end

  @doc "The event that tells the owner one invitation was accepted."
  @spec acceptance_owner_event(Project.t(), ProjectMemberProfile.t(), map()) :: map()
  def acceptance_owner_event(%Project{} = project, %ProjectMemberProfile{} = profile, owner) do
    minimized_payload!(%{
      account_id: owner.account_id,
      event_type: "participation.participant_joined",
      subject_ref: profile.id,
      event_version: 1,
      title: "Someone joined #{project.name}",
      body: "#{profile.display_name} accepted an invitation to #{project.name}.",
      project_label: project.name,
      actor_label: profile.display_name,
      link_path: participation_path(project)
    })
  end

  @doc "The event that tells the owner one invitation was declined."
  @spec decline_owner_event(Project.t(), ProjectInvitation.t(), map()) :: map()
  def decline_owner_event(%Project{} = project, %ProjectInvitation{} = invitation, owner) do
    minimized_payload!(%{
      account_id: owner.account_id,
      event_type: "participation.invitation_declined",
      subject_ref: invitation.id,
      event_version: invitation.credential_version,
      title: "An invitation was declined",
      body: "One invitation to #{project.name} was declined.",
      project_label: project.name,
      link_path: participation_path(project),
      occurred_at: invitation.terminal_at
    })
  end

  @doc """
  The event that tells a removed person at their account boundary.

  The link stays at the account level because project access has already ended;
  it restores nothing.
  """
  @spec removal_event(Project.t(), map()) :: map()
  def removal_event(%Project{} = project, revocation) do
    minimized_payload!(%{
      account_id: revocation.former_account_id,
      event_type: "participation.removed",
      subject_ref: revocation.id,
      event_version: revocation.contract_version,
      title: "You were removed from #{project.name}",
      body: "You no longer have access to #{project.name}. Your account is unchanged.",
      project_label: project.name,
      link_path: "/hosted/access/sessions",
      occurred_at: revocation.occurred_at
    })
  end

  @doc "The event that tells the owner one participant left."
  @spec leave_event(Project.t(), map()) :: map()
  def leave_event(%Project{} = project, revocation) do
    minimized_payload!(%{
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
    })
  end

  @spec participation_path(Project.t()) :: String.t()
  def participation_path(%Project{id: id}), do: "/projects/#{id}/participation"

  @spec project_path(Project.t()) :: String.t()
  def project_path(%Project{id: id}), do: "/projects/#{id}"

  defp minimized_payload!(payload) do
    case validate_payload(payload) do
      :ok -> payload
      {:error, reason} -> raise ArgumentError, "invalid participation notification: #{reason}"
    end
  end

  defp safe_link?("participation.removed", "/hosted/access/sessions"), do: true

  defp safe_link?(event_type, link_path) when event_type in @project_links,
    do: project_link?(link_path, false)

  defp safe_link?(event_type, link_path) when event_type in @participation_links,
    do: project_link?(link_path, true)

  defp safe_link?(_event_type, _link_path), do: false

  defp approved_content?(%{
         event_type: "participation.invitation_expired",
         title: "An invitation expired",
         body: body,
         project_label: project_label
       })
       when is_binary(project_label),
       do: body == "One invitation to #{project_label} expired before it was accepted."

  defp approved_content?(%{
         event_type: "participation.joined",
         title: title,
         body: body,
         project_label: project_label,
         actor_label: actor_label
       })
       when is_binary(project_label) and is_binary(actor_label),
       do:
         title == "You joined #{project_label}" and
           body == "You are now on #{project_label} as #{actor_label}."

  defp approved_content?(%{
         event_type: "participation.participant_joined",
         title: title,
         body: body,
         project_label: project_label,
         actor_label: actor_label
       })
       when is_binary(project_label) and is_binary(actor_label),
       do:
         title == "Someone joined #{project_label}" and
           body == "#{actor_label} accepted an invitation to #{project_label}."

  defp approved_content?(%{
         event_type: "participation.invitation_declined",
         title: "An invitation was declined",
         body: body,
         project_label: project_label
       })
       when is_binary(project_label),
       do: body == "One invitation to #{project_label} was declined."

  defp approved_content?(%{
         event_type: "participation.removed",
         title: title,
         body: body,
         project_label: project_label
       })
       when is_binary(project_label),
       do:
         title == "You were removed from #{project_label}" and
           body == "You no longer have access to #{project_label}. Your account is unchanged."

  defp approved_content?(%{
         event_type: "participation.left",
         title: title,
         body: body,
         project_label: project_label,
         actor_label: actor_label
       })
       when is_binary(project_label) and (is_binary(actor_label) or is_nil(actor_label)) do
    display_name = actor_label || "A participant"

    title == "Someone left #{project_label}" and body == "#{display_name} left #{project_label}."
  end

  defp approved_content?(_payload), do: false

  defp project_link?(link_path, participation?) do
    expected_suffix = if participation?, do: ["participation"], else: []

    case String.split(link_path, "/", trim: true) do
      ["projects", project_id | suffix] ->
        suffix == expected_suffix and match?({:ok, _uuid}, Ecto.UUID.cast(project_id))

      _other ->
        false
    end
  end
end
