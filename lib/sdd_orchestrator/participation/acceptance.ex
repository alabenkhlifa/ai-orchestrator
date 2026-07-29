defmodule SddOrchestrator.Participation.Acceptance do
  @moduledoc """
  Turns one proven invitation into exactly one active participant.

  Acceptance is a single transaction: it locks the invitation row, revalidates
  that the acting identity freshly proved the invited address, creates the
  participant authorization and its project display profile, consumes the
  invitation, and enqueues the outcome notifications. Any failure leaves the
  project exactly as it was — no participant, no profile, no consumed
  invitation, and no notification.

  Repeating an accepted invitation returns the participation that already
  exists instead of creating a second one, and every unusable path returns one
  safe result that exposes no unrelated account data.
  """

  import Ecto.Query

  alias Ecto.Multi

  alias SddOrchestrator.Accounts.HostedIdentity
  alias SddOrchestrator.Notifications
  alias SddOrchestrator.Participation

  alias SddOrchestrator.Participation.{
    InvitationProof,
    ProjectInvitation,
    ProjectMemberProfile,
    ProjectNotifications,
    ProjectParticipant
  }

  alias SddOrchestrator.Projects.Project
  alias SddOrchestrator.Repo

  @type accept_error :: :invalid_or_expired | :invalid_display_name | :display_name_taken

  @type accepted :: %{
          participant: ProjectParticipant.t(),
          profile: ProjectMemberProfile.t(),
          project: Project.t()
        }

  @doc """
  Accepts one invitation for the identity that proved its address.
  """
  @spec accept(term(), HostedIdentity.t() | nil, term(), DateTime.t()) ::
          {:ok, accepted()} | {:error, accept_error()}
  def accept(invitation_id, identity, display_name, now \\ DateTime.utc_now())

  def accept(invitation_id, %HostedIdentity{} = identity, display_name, now)
      when is_binary(invitation_id) do
    now = DateTime.truncate(now, :second)

    case existing_participation(invitation_id, identity) do
      {:ok, accepted} -> {:ok, accepted}
      :error -> run_acceptance(invitation_id, identity, display_name, now)
    end
  end

  def accept(_invitation_id, _identity, _display_name, _now), do: {:error, :invalid_or_expired}

  @doc """
  Declines one invitation for the identity that proved its address.

  Declining is terminal and creates no access. The owner is told the outcome,
  and a later invitation requires a fresh flow.
  """
  @spec decline(term(), HostedIdentity.t() | nil, DateTime.t()) ::
          {:ok, ProjectInvitation.t()} | {:error, :invalid_or_expired}
  def decline(invitation_id, identity, now \\ DateTime.utc_now())

  def decline(invitation_id, %HostedIdentity{} = identity, now) when is_binary(invitation_id) do
    now = DateTime.truncate(now, :second)

    Multi.new()
    |> Multi.run(:invitation, fn repo, _changes ->
      claim(repo, invitation_id, identity, now)
    end)
    |> Multi.run(:project, fn repo, %{invitation: invitation} ->
      fetch_project(repo, invitation.project_id)
    end)
    |> Multi.update(:declined, fn %{invitation: invitation} ->
      ProjectInvitation.terminal_changeset(invitation, "declined", "declined", now)
    end)
    |> Multi.insert(
      :owner_notification,
      fn %{project: project, declined: declined} ->
        Notifications.changeset(decline_event(project, declined))
      end,
      Notifications.insert_options()
    )
    |> Repo.transaction()
    |> case do
      {:ok, %{declined: declined}} -> {:ok, declined}
      {:error, _step, _reason, _changes} -> {:error, :invalid_or_expired}
    end
  end

  def decline(_invitation_id, _identity, _now), do: {:error, :invalid_or_expired}

  defp run_acceptance(invitation_id, identity, display_name, now) do
    Multi.new()
    |> Multi.run(:invitation, fn repo, _changes ->
      claim(repo, invitation_id, identity, now)
    end)
    |> Multi.run(:project, fn repo, %{invitation: invitation} ->
      fetch_project(repo, invitation.project_id)
    end)
    |> Multi.insert(:participant, fn %{invitation: invitation} ->
      ProjectParticipant.activation_changeset(%ProjectParticipant{}, %{
        project_id: invitation.project_id,
        hosted_identity_id: identity.id,
        joined_at: now
      })
    end)
    |> Multi.insert(:profile, fn %{invitation: invitation} ->
      ProjectMemberProfile.changeset(%ProjectMemberProfile{}, %{
        project_id: invitation.project_id,
        account_id: identity.account_id,
        role: "participant",
        display_name: display_name
      })
    end)
    |> Multi.update(:consumed, fn %{invitation: invitation} ->
      ProjectInvitation.terminal_changeset(invitation, "accepted", "accepted", now)
    end)
    |> Multi.insert(
      :participant_notification,
      fn %{project: project, profile: profile} ->
        project
        |> ProjectNotifications.acceptance_participant_event(profile, identity)
        |> Notifications.changeset()
      end,
      Notifications.insert_options()
    )
    |> Multi.insert(
      :owner_notification,
      fn %{project: project, profile: profile} ->
        Notifications.changeset(owner_event(project, profile))
      end,
      Notifications.insert_options()
    )
    |> Repo.transaction()
    |> case do
      {:ok, changes} -> {:ok, result(changes)}
      {:error, step, reason, _changes} -> {:error, failure(step, reason)}
    end
  end

  # The owner is resolved inside the transaction so the notification always
  # names the project's current immutable owner.
  defp owner_event(project, profile) do
    {:ok, owner} = Participation.owner(project)
    ProjectNotifications.acceptance_owner_event(project, profile, owner)
  end

  defp decline_event(project, invitation) do
    {:ok, owner} = Participation.owner(project)
    ProjectNotifications.decline_owner_event(project, invitation, owner)
  end

  # The invitation must still be pending, unexpired, and proven by this identity
  # at the moment it is consumed, not only when the page was rendered.
  defp claim(repo, invitation_id, identity, now) do
    ProjectInvitation
    |> where([i], i.id == ^invitation_id and i.status == "pending")
    |> lock("FOR UPDATE")
    |> repo.one()
    |> case do
      nil -> {:error, :invalid_or_expired}
      invitation -> validate_claim(invitation, identity, now)
    end
  rescue
    Ecto.Query.CastError -> {:error, :invalid_or_expired}
  end

  defp validate_claim(invitation, identity, now) do
    expired? = ProjectInvitation.expired?(invitation, now)
    proven? = InvitationProof.proof_state(invitation, identity) == :proven

    if expired? or not proven?, do: {:error, :invalid_or_expired}, else: {:ok, invitation}
  end

  defp fetch_project(repo, project_id) do
    case repo.get(Project, project_id) do
      nil -> {:error, :invalid_or_expired}
      project -> {:ok, project}
    end
  end

  defp existing_participation(invitation_id, identity) do
    with %ProjectInvitation{status: "accepted"} = invitation <-
           Repo.get(ProjectInvitation, invitation_id),
         %ProjectParticipant{} = participant <-
           Participation.active_participant(invitation.project_id, identity.id),
         %ProjectMemberProfile{} = profile <-
           Participation.member_profile(invitation.project_id, identity.account_id),
         %Project{} = project <- Repo.get(Project, invitation.project_id) do
      {:ok, %{participant: participant, profile: profile, project: project}}
    else
      _other -> :error
    end
  rescue
    Ecto.Query.CastError -> :error
  end

  defp result(%{participant: participant, profile: profile, project: project}),
    do: %{participant: participant, profile: profile, project: project}

  defp failure(:invitation, reason) when is_atom(reason), do: reason
  defp failure(:project, reason) when is_atom(reason), do: reason
  defp failure(:participant, _changeset), do: :invalid_or_expired
  defp failure(:profile, %Ecto.Changeset{} = changeset), do: profile_failure(changeset)
  defp failure(_step, _reason), do: :invalid_or_expired

  defp profile_failure(changeset) do
    case changeset.errors[:display_name] do
      {"is already used in this project", _opts} -> :display_name_taken
      {_message, _opts} -> :invalid_display_name
      nil -> :invalid_display_name
    end
  end
end
