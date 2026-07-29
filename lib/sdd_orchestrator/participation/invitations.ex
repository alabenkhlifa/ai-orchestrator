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

  require Logger

  alias SddOrchestrator.Accounts.ExternalIdentity
  alias SddOrchestrator.Participation

  alias SddOrchestrator.Participation.{
    EmailDelivery,
    EmailDigest,
    ParticipationEmail,
    ProjectInvitation
  }

  alias SddOrchestrator.Projects.Project
  alias SddOrchestrator.Repo

  @token_bytes 32
  @salt_bytes 32

  @type create_error ::
          :unauthorized
          | :not_hosted_project
          | :owner_profile_required
          | :invalid_email
          | :invitation_already_pending

  @doc """
  Creates one pending invitation for an owned hosted project and sends its email.

  Returns the invitation together with the delivery outcome. The raw credential
  is returned only to the caller that delivers it and is never persisted.
  """
  @spec create(Project.t() | Ecto.UUID.t(), Ecto.UUID.t() | nil, term()) ::
          {:ok, %{invitation: ProjectInvitation.t(), delivery: term()}} | {:error, create_error()}
  def create(project, account_id, email) do
    with {:ok, project, owner} <- authorize(project, account_id),
         :ok <- require_owner_profile(project),
         {:ok, normalized} <- ExternalIdentity.normalize_email(email),
         {:ok, %{invitation: invitation, raw_token: raw_token}} <-
           insert(project, owner, normalized) do
      {:ok, %{invitation: invitation, delivery: send_invitation(project, invitation, raw_token)}}
    end
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

  defp require_owner_profile(project) do
    if Participation.owner_profile_established?(project.id),
      do: :ok,
      else: {:error, :owner_profile_required}
  end

  defp insert(project, owner, normalized) do
    credential = new_credential()
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %ProjectInvitation{}
    |> ProjectInvitation.changeset(%{
      project_id: project.id,
      invited_by_account_id: owner.account_id,
      email_digest: EmailDigest.from_subject_key(normalized.subject_key),
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

  defp send_invitation(project, invitation, raw_token) do
    EmailDelivery.deliver(:invitation, %{
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
