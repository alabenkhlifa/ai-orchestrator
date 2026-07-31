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
    * Reads are minimal. A member is returned as a stable identity, a role, and
      a project display name. Email addresses never cross this boundary;
      membership management keeps them inside this specification.

  Nothing here mutates participation, and this specification never mutates a
  consumer's records. A departure publishes one versioned
  `ParticipationRevocation`; the consumer claims it, applies its own behavior,
  and acknowledges it. In-product events extend the shared account-level
  notification store under the consumer's own event namespace rather than
  creating a second store.
  """

  alias SddOrchestrator.Notifications
  alias SddOrchestrator.Notifications.AccountNotification
  alias SddOrchestrator.Participation
  alias SddOrchestrator.Participation.{Capabilities, ParticipationRevocation, Revocations}
  alias SddOrchestrator.Projects.Project

  @contract_version 1

  @type member :: %{
          role: :owner | :participant,
          account_id: Ecto.UUID.t(),
          hosted_identity_id: Ecto.UUID.t() | nil,
          display_name: String.t()
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
      {:ok, owner} -> {:ok, member(:owner, owner.account_id, nil, owner_label(project_id))}
      {:error, _reason} -> {:error, :unavailable}
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
    project_id
    |> Participation.active_participants()
    |> Enum.map(&participant_member(project_id, &1))
    |> Enum.reject(&is_nil/1)
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
  defp owner_label(project_id) do
    case Participation.owner_profile(project_id) do
      nil -> Participation.default_owner_display_name()
      profile -> profile.display_name
    end
  end

  defp owner_member(project_id) do
    case owner(project_id) do
      {:ok, entry} -> {:ok, entry}
      {:error, :unavailable} -> {:error, :not_a_member}
    end
  end

  defp participant_member_for(project_id, hosted_identity_id) do
    case Participation.active_participant(project_id, hosted_identity_id) do
      nil -> {:error, :not_a_member}
      participant -> wrap(participant_member(project_id, participant))
    end
  end

  defp wrap(nil), do: {:error, :not_a_member}
  defp wrap(member), do: {:ok, member}

  defp participant_member(project_id, participant) do
    with account_id when not is_nil(account_id) <- account_id_of(participant),
         profile when not is_nil(profile) <- Participation.member_profile(project_id, account_id) do
      member(:participant, account_id, participant.hosted_identity_id, profile.display_name)
    else
      _other -> nil
    end
  end

  defp account_id_of(%{hosted_identity_id: nil}), do: nil

  defp account_id_of(%{hosted_identity_id: hosted_identity_id}) do
    case SddOrchestrator.Repo.get(SddOrchestrator.Accounts.HostedIdentity, hosted_identity_id) do
      nil -> nil
      identity -> identity.account_id
    end
  end

  # The minimum result: stable identity, role, and project label. No address.
  defp member(role, account_id, hosted_identity_id, display_name) do
    %{
      role: role,
      account_id: account_id,
      hosted_identity_id: hosted_identity_id,
      display_name: display_name
    }
  end
end
