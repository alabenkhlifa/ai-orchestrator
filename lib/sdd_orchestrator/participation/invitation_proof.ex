defmodule SddOrchestrator.Participation.InvitationProof do
  @moduledoc """
  Invitation-bound proof of the invited email address.

  Opening an invitation proves possession of its credential, not of its
  address. Proof is requested for the address stored on the invitation — never
  for an address the visitor types — and is issued through the existing
  passwordless boundary, so the invited person becomes the proven stable hosted
  identity in this browser.

  An active session for another identity is never accepted as proof. It is
  replaced in this browser only after the invited address is freshly proven,
  and the other identity's server-side sessions are left untouched.

  Proof alone grants no project access: acceptance is a separate explicit act.
  """

  alias SddOrchestrator.Accounts.HostedIdentity
  alias SddOrchestrator.HostedAccess
  alias SddOrchestrator.Participation.{EmailDigest, Invitations, ProjectInvitation}
  alias SddOrchestrator.Projects.Project
  alias SddOrchestrator.Repo

  @type opened :: %{
          invitation: ProjectInvitation.t(),
          project: Project.t(),
          invited_email: String.t()
        }

  @doc """
  Resolves one invitation from its identifier and delivered credential.

  Every unusable case — unknown, malformed, expired, canceled, declined, or
  already accepted — returns the same safe result.
  """
  @spec open(term(), term(), DateTime.t()) :: {:ok, opened()} | {:error, :invalid_or_expired}
  def open(invitation_id, raw_token, now \\ DateTime.utc_now())

  def open(invitation_id, raw_token, now)
      when is_binary(invitation_id) and is_binary(raw_token) do
    with %ProjectInvitation{} = invitation <- Invitations.usable(invitation_id, now),
         true <- credential_matches?(invitation, raw_token),
         %Project{} = project <- Repo.get(Project, invitation.project_id) do
      {:ok, %{invitation: invitation, project: project, invited_email: invitation.delivery_email}}
    else
      _other -> {:error, :invalid_or_expired}
    end
  end

  def open(_invitation_id, _raw_token, _now), do: {:error, :invalid_or_expired}

  @doc """
  Resolves one invitation for a browser that has already proven its address.

  The delivered credential is not carried through the proof round trip, so the
  return visit is authorized by the proven identity itself.
  """
  @spec open_for_identity(term(), HostedIdentity.t() | nil, DateTime.t()) ::
          {:ok, opened()} | {:error, :invalid_or_expired}
  def open_for_identity(invitation_id, identity, now \\ DateTime.utc_now())

  def open_for_identity(invitation_id, %HostedIdentity{} = identity, now)
      when is_binary(invitation_id) do
    with %ProjectInvitation{} = invitation <- Invitations.usable(invitation_id, now),
         :proven <- proof_state(invitation, identity),
         %Project{} = project <- Repo.get(Project, invitation.project_id) do
      {:ok, %{invitation: invitation, project: project, invited_email: invitation.delivery_email}}
    else
      _other -> {:error, :invalid_or_expired}
    end
  end

  def open_for_identity(_invitation_id, _identity, _now), do: {:error, :invalid_or_expired}

  @doc """
  Requests fresh proof of the invited address for this browser.

  The acknowledgement is account-neutral and identical whether or not that
  address already has an account.
  """
  @spec request(opened(), map()) :: {:ok, %{status: :accepted}}
  def request(%{invitation: invitation}, context \\ %{}) do
    HostedAccess.request_magic_link(
      invitation.delivery_email,
      Map.put(context, :return_to, return_path(invitation))
    )
  end

  @doc "The application-local path the proof returns to."
  @spec return_path(ProjectInvitation.t()) :: String.t()
  def return_path(%ProjectInvitation{id: id}), do: "/projects/invitations/#{id}/accept"

  @doc """
  Reports whether the current browser identity is the freshly proven invitee.

  A different active identity is `:different_email`, and an absent identity is
  `:proof_required`; neither is treated as proof.
  """
  @spec proof_state(ProjectInvitation.t(), HostedIdentity.t() | nil) ::
          :proven | :different_email | :proof_required
  def proof_state(_invitation, nil), do: :proof_required

  def proof_state(%ProjectInvitation{} = invitation, %HostedIdentity{} = identity) do
    if identity |> verified_digests() |> Enum.any?(&matches_digest?(&1, invitation)) do
      :proven
    else
      :different_email
    end
  end

  defp verified_digests(identity) do
    identity
    |> Repo.preload(:external_identities)
    |> Map.fetch!(:external_identities)
    |> Enum.filter(&(&1.provider == "email"))
    |> Enum.map(&EmailDigest.from_subject_key(&1.subject_key))
  end

  defp matches_digest?(digest, %ProjectInvitation{email_digest: expected}),
    do: :crypto.hash_equals(digest, expected)

  defp credential_matches?(%ProjectInvitation{token_digest: digest, token_salt: salt}, raw_token)
       when is_binary(digest) and is_binary(salt) do
    :crypto.hash_equals(digest, :crypto.hash(:sha256, salt <> raw_token))
  end

  defp credential_matches?(_invitation, _raw_token), do: false
end
