defmodule SddOrchestrator.Participation.Boundary do
  @moduledoc """
  The published current-participant authorization boundary.

  This is the whole contract approved consumers may use. It answers who is a
  current member of one project, what they may currently do there, how they are
  labelled, and how a departure is handed off — and nothing else.

  Three properties matter to a consumer:

    * Reads are direct. Every call resolves current state, so removal and leave
      take effect on the very next question. There is no cache to invalidate.
    * Reads are fail-closed. A stale, removed, departed, absent, or
      cross-project identity is denied, and the result never says why.
    * Reads are minimal. A member is returned as a stable identity, a role, a
      presentation state, and a project display name. Missing presentation uses
      only a neutral role label. Email addresses never cross this boundary;
      membership management keeps them inside this specification.

  Nothing here mutates participation, and this specification never mutates a
  consumer's records. A departure publishes one versioned
  `ParticipationRevocation`; the consumer claims it, applies its own behavior,
  and acknowledges it. In-product events extend the shared account-level
  notification store under the consumer's own event namespace rather than
  creating a second store.
  """

  import Ecto.Query

  alias SddOrchestrator.Accounts.HostedIdentity
  alias SddOrchestrator.Notifications
  alias SddOrchestrator.Notifications.AccountNotification
  alias SddOrchestrator.Participation

  alias SddOrchestrator.Participation.{
    Capabilities,
    ParticipationRevocation,
    ProjectMemberProfile,
    ProjectParticipant,
    Revocations
  }

  alias SddOrchestrator.Projects.Project
  alias SddOrchestrator.Repo

  @contract_version 1
  @default_participant_display_name "Project participant"

  @type member :: %{
          role: :owner | :participant,
          account_id: Ecto.UUID.t(),
          hosted_identity_id: Ecto.UUID.t() | nil,
          display_name: String.t(),
          presentation_state: :present | :absent
        }

  @doc "The version of this consumer contract."
  @spec contract_version() :: pos_integer()
  def contract_version, do: @contract_version

  @doc """
  Returns the project's immutable owner as a minimum member result.

  The owner is the deterministic fallback a consumer routes pending
  responsibility to when a participant departs.
  """
  @spec owner(Ecto.UUID.t()) :: {:ok, member()} | {:error, :unavailable}
  def owner(project_id) do
    case Participation.owner(project_id) do
      {:ok, owner} ->
        {display_name, presentation_state} = owner_presentation(project_id)

        {:ok, member(:owner, owner.account_id, nil, display_name, presentation_state)}

      {:error, _reason} ->
        {:error, :unavailable}
    end
  end

  @doc "Lists every current member of one project, owner first."
  @spec current_members(Ecto.UUID.t()) :: [member()]
  def current_members(project_id) do
    owner_entry =
      case owner(project_id) do
        {:ok, entry} -> [entry]
        {:error, :unavailable} -> []
      end

    owner_entry ++ current_participants(project_id)
  end

  @doc "Lists the project's current active participants."
  @spec current_participants(Ecto.UUID.t()) :: [member()]
  def current_participants(project_id) do
    ProjectParticipant
    |> join(:inner, [participant], identity in HostedIdentity,
      on: identity.id == participant.hosted_identity_id
    )
    |> join(:left, [participant, identity], profile in ProjectMemberProfile,
      on:
        profile.project_id == participant.project_id and
          profile.account_id == identity.account_id and profile.role == "participant" and
          profile.state == "active"
    )
    |> where(
      [participant],
      participant.project_id == ^project_id and participant.state == "active"
    )
    |> order_by([participant], asc: participant.joined_at, asc: participant.id)
    |> select([participant, identity, profile], {
      participant.hosted_identity_id,
      identity.account_id,
      profile.display_name
    })
    |> Repo.all()
    |> Enum.map(&participant_member/1)
  rescue
    Ecto.Query.CastError -> []
  end

  @doc """
  Resolves one current member of one project.

  A stale, removed, departed, absent, or cross-project identity returns the
  same denial without disclosing which case applied.
  """
  @spec current_member(Ecto.UUID.t(), map()) :: {:ok, member()} | {:error, :not_a_member}
  def current_member(project_id, actor) do
    account_id = Map.get(actor, :account_id)
    hosted_identity_id = Map.get(actor, :hosted_identity_id)

    case Participation.member_role(project_id, account_id, hosted_identity_id) do
      {:ok, :owner} -> owner_member(project_id)
      {:ok, :participant} -> participant_member_for(project_id, hosted_identity_id)
      {:error, :unauthorized} -> {:error, :not_a_member}
    end
  end

  @doc "Reports whether one actor currently holds one project capability."
  @spec authorized?(Project.t() | Ecto.UUID.t(), map(), atom()) :: boolean()
  def authorized?(project, actor, capability),
    do: Capabilities.can?(project, actor, capability)

  @doc "The capabilities one actor currently holds in one project."
  @spec capabilities(Project.t() | Ecto.UUID.t(), map()) :: [atom()]
  def capabilities(project, actor), do: Capabilities.capabilities(project, actor)

  @doc """
  Claims the departure handoffs a consumer has not acknowledged yet.

  Claiming only marks delivery. A consumer that fails before acknowledging sees
  the same handoff again, so its own handling must be idempotent.
  """
  @spec claim_revocations(keyword()) :: [ParticipationRevocation.t()]
  def claim_revocations(opts \\ []), do: Revocations.claim(opts)

  @doc "Lists unacknowledged departure handoffs without claiming them."
  @spec pending_revocations(keyword()) :: [ParticipationRevocation.t()]
  def pending_revocations(opts \\ []), do: Revocations.pending(opts)

  @doc "Records that a consumer committed its own handling of one handoff."
  @spec acknowledge_revocation(Ecto.UUID.t(), String.t()) ::
          {:ok, ParticipationRevocation.t()} | {:error, :not_found}
  def acknowledge_revocation(revocation_id, consumer_ref),
    do: Revocations.acknowledge(revocation_id, consumer_ref)

  @doc """
  Creates one in-product notification through the shared account-level store.

  A consumer supplies its own namespaced event type; this boundary adds no
  second notification store and applies the same minimized field contract.
  """
  @spec notify(map()) :: {:ok, AccountNotification.t()} | {:error, Ecto.Changeset.t()}
  def notify(attrs), do: Notifications.deliver(attrs)

  @doc "The event namespaces the shared notification store accepts."
  @spec notification_namespaces() :: [String.t()]
  def notification_namespaces, do: AccountNotification.namespaces()

  # A label describes how the owner appears, not whether they are the owner.
  # Ownership is resolved from the project ownership boundary alone, so a
  # project created outside registration — or registered before owner profiles
  # were created with the project — still answers with its owner and simply
  # presents the neutral label until one is established.
  defp owner_presentation(project_id) do
    case Participation.owner_profile(project_id) do
      nil -> {Participation.default_owner_display_name(), :absent}
      profile -> {profile.display_name, :present}
    end
  end

  defp owner_member(project_id) do
    case owner(project_id) do
      {:ok, entry} -> {:ok, entry}
      {:error, :unavailable} -> {:error, :not_a_member}
    end
  end

  defp participant_member_for(project_id, hosted_identity_id) do
    case Enum.find(
           current_participants(project_id),
           &(&1.hosted_identity_id == hosted_identity_id)
         ) do
      nil -> {:error, :not_a_member}
      participant -> {:ok, participant}
    end
  end

  defp participant_member({hosted_identity_id, account_id, nil}) do
    member(
      :participant,
      account_id,
      hosted_identity_id,
      @default_participant_display_name,
      :absent
    )
  end

  defp participant_member({hosted_identity_id, account_id, display_name}) do
    member(:participant, account_id, hosted_identity_id, display_name, :present)
  end

  # The minimum result: stable identity, role, presentation state, and a safe
  # project label. No address.
  defp member(role, account_id, hosted_identity_id, display_name, presentation_state) do
    %{
      role: role,
      account_id: account_id,
      hosted_identity_id: hosted_identity_id,
      display_name: display_name,
      presentation_state: presentation_state
    }
  end
end
