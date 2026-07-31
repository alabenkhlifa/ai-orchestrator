defmodule SddOrchestrator.Participation.Invitations do
  @moduledoc """
  Owner-created project invitations.

  Creation never searches for an account. The submitted address is normalized,
  digested for uniqueness, stored encrypted, and given one salted single-use
  credential with a seven-day lifetime in one atomic insert whose pending
  uniqueness index resolves concurrent requests. The email is sent afterwards
  through the participation delivery boundary, so a provider outage leaves a
  recoverable pending invitation rather than a half-created one.

  Failures are project-scoped facts the owner is already authorized to see —
  not authorization, device-storage, or address-shape state of anyone else — and
  no result reveals whether the address already has an account.
  """

  import Ecto.Query

  require Logger

  alias SddOrchestrator.Accounts.ExternalIdentity
  alias SddOrchestrator.Participation

  alias SddOrchestrator.Participation.{
    EmailDelivery,
    EmailDigest,
    ParticipationEmail,
    ProjectInvitation,
    ProjectNotifications,
    ProjectRoles
  }

  alias SddOrchestrator.Projects.Project
  alias SddOrchestrator.Repo

  @token_bytes 32
  @salt_bytes 32

  @type create_error ::
          :unauthorized
          | :not_hosted_project
          | :invalid_email
          | :invitation_already_pending
          | {:existing_role, ProjectRoles.role()}

  @doc """
  Creates one pending invitation for an owned hosted project and sends its email.

  Returns the invitation together with the delivery outcome. The raw credential
  is returned only to the caller that delivers it and is never persisted.
  """
  @spec create(Project.t() | Ecto.UUID.t(), Ecto.UUID.t() | nil, term()) ::
          {:ok, %{invitation: ProjectInvitation.t(), delivery: term()}} | {:error, create_error()}
  def create(project, account_id, email) do
    with {:ok, project, owner} <- authorize(project, account_id),
         {:ok, normalized} <- ExternalIdentity.normalize_email(email),
         digest = EmailDigest.from_subject_key(normalized.subject_key),
         :ok <- reject_existing_member(project, digest),
         {:ok, %{invitation: invitation, raw_token: raw_token}} <-
           insert(project, owner, normalized, digest) do
      {:ok, %{invitation: invitation, delivery: send_invitation(project, invitation, raw_token)}}
    end
  end

  @doc """
  Replaces the credential of the current pending invitation for one address.

  The prior link stops working immediately: the row keeps its identity and its
  one-pending position while its salted digest, salt, credential version, and
  seven-day expiry are all replaced under a row lock, so two concurrent resends
  cannot produce two usable links.
  """
  @spec resend(Project.t() | Ecto.UUID.t(), Ecto.UUID.t() | nil, term()) ::
          {:ok, %{invitation: ProjectInvitation.t(), delivery: term()}}
          | {:error, create_error() | :no_pending_invitation}
  def resend(project, account_id, email) do
    with {:ok, project, _owner} <- authorize(project, account_id),
         {:ok, normalized} <- ExternalIdentity.normalize_email(email),
         digest = EmailDigest.from_subject_key(normalized.subject_key),
         :ok <- reject_existing_member(project, digest),
         {:ok, %{invitation: invitation, raw_token: raw_token}} <- rotate(project, digest) do
      {:ok,
       %{
         invitation: invitation,
         delivery: send_invitation(:invitation_resent, project, invitation, raw_token)
       }}
    end
  end

  @doc """
  Cancels the pending invitation for one address.

  Cancellation is terminal and immediate: the credential digest and salt are
  erased in the same update, so the delivered link stops working and a later
  invitation requires a fresh flow. Repeating the action on an already canceled
  invitation succeeds without sending a second message.
  """
  @spec cancel(Project.t() | Ecto.UUID.t(), Ecto.UUID.t() | nil, term()) ::
          {:ok, ProjectInvitation.t()}
          | {:error, create_error() | :no_pending_invitation | :not_cancelable}
  def cancel(project, account_id, email) do
    with {:ok, project, _owner} <- authorize(project, account_id),
         {:ok, normalized} <- ExternalIdentity.normalize_email(email),
         digest = EmailDigest.from_subject_key(normalized.subject_key),
         {:ok, {invitation, transitioned?}} <- terminate(project, digest, "canceled", "canceled") do
      if transitioned?, do: send_cancellation(project, invitation)
      {:ok, invitation}
    end
  end

  @doc """
  Ends every pending invitation whose seven-day lifetime has passed.

  The transition is idempotent and changes no participant record; it only makes
  the credential unusable and records the terminal state for the owner.
  """
  @spec expire_due(DateTime.t()) :: non_neg_integer()
  def expire_due(now \\ DateTime.utc_now()) do
    now = DateTime.truncate(now, :second)

    ProjectInvitation
    |> where([i], i.status == "pending" and i.expires_at <= ^now)
    |> select([i], i.id)
    |> Repo.all()
    |> Enum.count(&expire_one(&1, now))
  end

  @doc "Returns the pending invitation that is still usable at `now`."
  @spec usable(Ecto.UUID.t(), DateTime.t()) :: ProjectInvitation.t() | nil
  def usable(invitation_id, now \\ DateTime.utc_now()) do
    case Repo.get(ProjectInvitation, invitation_id) do
      %ProjectInvitation{status: "pending"} = invitation ->
        if ProjectInvitation.expired?(invitation, now), do: nil, else: invitation

      _other ->
        nil
    end
  rescue
    Ecto.Query.CastError -> nil
  end

  @doc """
  Lists one project's invitations for membership management, newest first.

  The result carries lifecycle state and delivery address only; credential
  material is never present because a terminal invitation has none and a
  pending one is redacted from inspection.
  """
  @spec list(Ecto.UUID.t()) :: [ProjectInvitation.t()]
  def list(project_id) do
    ProjectInvitation
    |> where([i], i.project_id == ^project_id)
    |> order_by([i], desc: i.inserted_at, desc: i.id)
    |> Repo.all()
  rescue
    Ecto.Query.CastError -> []
  end

  @doc "Returns the current pending invitation for one project and address."
  @spec pending_for(Ecto.UUID.t(), term()) :: ProjectInvitation.t() | nil
  def pending_for(project_id, email) do
    case EmailDigest.compute(email) do
      {:ok, digest} ->
        Repo.get_by(ProjectInvitation,
          project_id: project_id,
          email_digest: digest,
          status: "pending"
        )

      {:error, :invalid_email} ->
        nil
    end
  end

  @doc "Generates one raw credential and its salted digest."
  @spec new_credential() :: %{raw_token: String.t(), token_digest: binary(), token_salt: binary()}
  def new_credential do
    raw_token = Base.url_encode64(:crypto.strong_rand_bytes(@token_bytes), padding: false)
    salt = :crypto.strong_rand_bytes(@salt_bytes)

    %{
      raw_token: raw_token,
      token_salt: salt,
      token_digest: :crypto.hash(:sha256, salt <> raw_token)
    }
  end

  defp authorize(project, account_id) do
    with {:ok, resolved} <- resolve_project(project),
         {:ok, owner} <- owner_of(resolved, account_id) do
      {:ok, resolved, owner}
    end
  end

  defp resolve_project(%Project{} = project), do: {:ok, project}

  defp resolve_project(project_id) do
    case Repo.get(Project, project_id) do
      nil -> {:error, :unauthorized}
      project -> {:ok, project}
    end
  rescue
    Ecto.Query.CastError -> {:error, :unauthorized}
  end

  # A device-authoritative project has no hosted owner, so collaboration stays
  # unavailable and no invitation record is created.
  defp owner_of(%Project{storage_mode: "hosted"} = project, account_id) do
    case Participation.owner(project) do
      {:ok, %{account_id: ^account_id} = owner} when not is_nil(account_id) -> {:ok, owner}
      _other -> {:error, :unauthorized}
    end
  end

  defp owner_of(%Project{}, _account_id), do: {:error, :not_hosted_project}

  # An address that already belongs to the immutable owner or an active
  # participant creates no invitation and no credential. The owner sees the
  # existing project role because it is membership state they already hold.
  defp reject_existing_member(project, digest) do
    case ProjectRoles.existing_role(project, digest) do
      nil -> :ok
      role -> {:error, {:existing_role, role}}
    end
  end

  defp terminate(project, digest, status, reason) do
    Repo.transaction(fn ->
      case lock_current(project.id, digest) do
        nil -> Repo.rollback(:no_pending_invitation)
        invitation -> apply_termination(project, invitation, status, reason)
      end
    end)
  end

  defp apply_termination(
         _project,
         %ProjectInvitation{status: status} = invitation,
         status,
         _reason
       ),
       do: {invitation, false}

  defp apply_termination(
         project,
         %ProjectInvitation{status: "pending"} = invitation,
         status,
         reason
       ) do
    invitation
    |> ProjectInvitation.terminal_changeset(status, reason)
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        log(project, updated, "ended_#{reason}")
        {updated, true}

      {:error, changeset} ->
        Repo.rollback(insert_error(changeset))
    end
  end

  defp apply_termination(_project, _invitation, _status, _reason),
    do: Repo.rollback(:not_cancelable)

  defp expire_one(invitation_id, now) do
    Repo.transaction(fn ->
      ProjectInvitation
      |> where([i], i.id == ^invitation_id and i.status == "pending")
      |> lock("FOR UPDATE")
      |> Repo.one()
      |> case do
        nil -> nil
        invitation -> apply_expiry(invitation, now)
      end
    end)
    |> case do
      {:ok, nil} -> false
      {:ok, expired} -> notify_expiry(expired)
      {:error, _reason} -> false
    end
  end

  defp apply_expiry(invitation, now) do
    {:ok, expired} =
      invitation
      |> ProjectInvitation.terminal_changeset("expired", "expired", now)
      |> Repo.update()

    expired
  end

  # The owner learns that a pending invitation lapsed; the invited person never
  # had project access and receives no project notification.
  defp notify_expiry(expired) do
    case Repo.get(Project, expired.project_id) do
      nil ->
        true

      project ->
        project |> ProjectNotifications.invitation_expired(expired) |> then(fn _ -> true end)
    end
  end

  defp lock_current(project_id, digest) do
    ProjectInvitation
    |> where([i], i.project_id == ^project_id and i.email_digest == ^digest)
    |> order_by([i], desc: i.inserted_at, desc: i.id)
    |> limit(1)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp send_cancellation(project, invitation) do
    EmailDelivery.deliver(:invitation_canceled, %{
      subject_ref: invitation.id,
      event_version: invitation.credential_version,
      recipient: invitation.delivery_email,
      project_label: project.name
    })
  end

  defp rotate(project, digest) do
    credential = new_credential()
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.transaction(fn ->
      case lock_pending(project.id, digest) do
        nil -> Repo.rollback(:no_pending_invitation)
        invitation -> replace_credential(project, invitation, credential, now)
      end
    end)
  end

  defp replace_credential(project, invitation, credential, now) do
    invitation
    |> ProjectInvitation.credential_changeset(%{
      token_digest: credential.token_digest,
      token_salt: credential.token_salt,
      expires_at: ProjectInvitation.default_expiry(now)
    })
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        log(project, updated, "credential_replaced")
        %{invitation: updated, raw_token: credential.raw_token}

      {:error, changeset} ->
        Repo.rollback(insert_error(changeset))
    end
  end

  defp lock_pending(project_id, digest) do
    ProjectInvitation
    |> where(
      [i],
      i.project_id == ^project_id and i.email_digest == ^digest and i.status == "pending"
    )
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp insert(project, owner, normalized, digest) do
    credential = new_credential()
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %ProjectInvitation{}
    |> ProjectInvitation.changeset(%{
      project_id: project.id,
      invited_by_account_id: owner.account_id,
      email_digest: digest,
      delivery_email: normalized.display_identifier,
      token_digest: credential.token_digest,
      token_salt: credential.token_salt,
      expires_at: ProjectInvitation.default_expiry(now)
    })
    |> Repo.insert()
    |> case do
      {:ok, invitation} ->
        log(project, invitation, "created")
        {:ok, %{invitation: invitation, raw_token: credential.raw_token}}

      {:error, changeset} ->
        {:error, insert_error(changeset)}
    end
  end

  defp insert_error(changeset) do
    if Enum.any?(changeset.errors, fn {field, _error} -> field == :email_digest end),
      do: :invitation_already_pending,
      else: :invalid_email
  end

  defp send_invitation(event \\ :invitation, project, invitation, raw_token) do
    EmailDelivery.deliver(event, %{
      subject_ref: invitation.id,
      event_version: invitation.credential_version,
      recipient: invitation.delivery_email,
      project_label: project.name,
      url: ParticipationEmail.invitation_url(invitation.id, raw_token)
    })
  end

  # The structured event names the project and invitation only. The address, its
  # digest, and the credential never reach a log line.
  defp log(project, invitation, outcome) do
    Logger.info(
      "participation_invitation project_id=#{project.id} invitation_id=#{invitation.id} " <>
        "outcome=#{outcome}"
    )
  end
end
