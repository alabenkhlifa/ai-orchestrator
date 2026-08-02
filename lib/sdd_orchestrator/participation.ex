defmodule SddOrchestrator.Participation do
  @moduledoc """
  Hosted-project participation: the immutable owner, active participant
  authorizations, and the project-specific presentation profiles that label
  them.

  Authorization is read directly for every protected action rather than cached,
  so removal and leave take effect immediately. Nothing here mutates another
  specification's records; feature-delivery consumers read the current result
  and apply their own behavior.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias SddOrchestrator.Accounts
  alias SddOrchestrator.Accounts.{ExternalIdentity, HostedIdentity, PersonalWorkspace}

  alias SddOrchestrator.Participation.{
    DisplayName,
    ParticipationRevocation,
    ProjectMemberProfile,
    ProjectParticipant
  }

  alias SddOrchestrator.Projects.Project
  alias SddOrchestrator.Repo

  # The initial owner label used when the registering account has no usable
  # GitHub login. It is deliberately neutral and identifies nobody: an email
  # address must never become a project label, and deriving one from an email,
  # an account identifier, or any other stable key would push personal data
  # into a string every project member reads. A generic role word says only
  # what the reader already knows, and the owner may replace it at any time.
  @default_owner_display_name "Project owner"

  @type owner :: %{
          project_id: Ecto.UUID.t(),
          workspace_id: Ecto.UUID.t(),
          account_id: Ecto.UUID.t()
        }

  @doc """
  The neutral owner label used when no owner profile has been established.
  """
  @spec default_owner_display_name() :: String.t()
  def default_owner_display_name, do: @default_owner_display_name

  @doc """
  Derives the immutable project owner from the hosted project ownership
  boundary.

  A device-authoritative project has no hosted owner and cannot participate in
  hosted collaboration.
  """
  @spec owner(Project.t() | Ecto.UUID.t()) ::
          {:ok, owner()} | {:error, :not_hosted_project | :project_not_found}
  def owner(%Project{} = project), do: owner_for(project)

  def owner(project_id) when is_binary(project_id) do
    case get_project(project_id) do
      nil -> {:error, :project_not_found}
      project -> owner_for(project)
    end
  end

  def owner(_project), do: {:error, :project_not_found}

  @doc "Returns true only when the account is the current immutable project owner."
  @spec owner?(Project.t() | Ecto.UUID.t(), Ecto.UUID.t() | nil) :: boolean()
  def owner?(_project, nil), do: false

  def owner?(project, account_id) do
    case owner(project) do
      {:ok, %{account_id: ^account_id}} -> true
      _other -> false
    end
  end

  @doc """
  Returns the current active participant authorization for one hosted identity
  and project, or `nil` when it is absent, removed, or left.
  """
  @spec active_participant(Ecto.UUID.t(), Ecto.UUID.t() | nil) :: ProjectParticipant.t() | nil
  def active_participant(_project_id, nil), do: nil

  def active_participant(project_id, hosted_identity_id) do
    ProjectParticipant
    |> where(
      [p],
      p.project_id == ^project_id and p.hosted_identity_id == ^hosted_identity_id and
        p.state == "active"
    )
    |> Repo.one()
  rescue
    Ecto.Query.CastError -> nil
  end

  @doc "Lists the current active participant authorizations of one project."
  @spec active_participants(Ecto.UUID.t()) :: [ProjectParticipant.t()]
  def active_participants(project_id) do
    ProjectParticipant
    |> where([p], p.project_id == ^project_id and p.state == "active")
    |> order_by([p], asc: p.joined_at, asc: p.id)
    |> Repo.all()
  end

  @doc "Returns the current project profile of one account, when it exists."
  @spec member_profile(Ecto.UUID.t(), Ecto.UUID.t() | nil) :: ProjectMemberProfile.t() | nil
  def member_profile(_project_id, nil), do: nil

  def member_profile(project_id, account_id) do
    ProjectMemberProfile
    |> where([p], p.project_id == ^project_id and p.account_id == ^account_id)
    |> Repo.one()
  rescue
    Ecto.Query.CastError -> nil
  end

  @doc "Returns the current owner profile of one project, when it exists."
  @spec owner_profile(Ecto.UUID.t()) :: ProjectMemberProfile.t() | nil
  def owner_profile(project_id) do
    ProjectMemberProfile
    |> where([p], p.project_id == ^project_id and p.role == "owner" and p.state == "active")
    |> Repo.one()
  end

  @doc """
  Returns the hosted project one account owns, or a fail-closed error.

  Every participation-management surface resolves the project through this
  authorization check rather than trusting a routed identifier.
  """
  @spec owned_project(Ecto.UUID.t() | nil, Ecto.UUID.t()) ::
          {:ok, Project.t()} | {:error, :unauthorized}
  def owned_project(nil, _project_id), do: {:error, :unauthorized}

  def owned_project(account_id, project_id) do
    with project when not is_nil(project) <- get_project(project_id),
         {:ok, %{account_id: ^account_id}} <- owner(project) do
      {:ok, project}
    else
      _other -> {:error, :unauthorized}
    end
  end

  @doc """
  Resolves the role one visitor currently holds in a project.

  The owner is derived from project ownership and a participant from an active
  authorization for their stable hosted identity. Anything else fails closed.
  """
  @spec member_role(Project.t() | Ecto.UUID.t(), Ecto.UUID.t() | nil, Ecto.UUID.t() | nil) ::
          {:ok, :owner | :participant} | {:error, :unauthorized}
  def member_role(project, account_id, hosted_identity_id) do
    cond do
      not is_nil(account_id) and owner?(project, account_id) ->
        {:ok, :owner}

      not is_nil(hosted_identity_id) and active_participant?(project, hosted_identity_id) ->
        {:ok, :participant}

      true ->
        {:error, :unauthorized}
    end
  end

  @doc """
  Returns the project a visitor may read as owner or active participant.
  """
  @spec visible_project(Ecto.UUID.t(), Ecto.UUID.t() | nil, Ecto.UUID.t() | nil) ::
          {:ok, Project.t(), :owner | :participant} | {:error, :unauthorized}
  def visible_project(project_id, account_id, hosted_identity_id) do
    with project when not is_nil(project) <- get_project(project_id),
         {:ok, role} <- member_role(project, account_id, hosted_identity_id) do
      {:ok, project, role}
    else
      _other -> {:error, :unauthorized}
    end
  end

  @doc """
  Lists the project's current members as one viewer is allowed to see them.

  Every member is presented by project display name. The owner may see member
  email addresses for membership management; a participant may see only their
  own; nobody sees another participant's address.
  """
  @spec members(Project.t(), :owner | :participant, Ecto.UUID.t() | nil) :: [map()]
  def members(%Project{} = project, viewer_role, viewer_account_id) do
    project
    |> member_entries()
    |> Enum.map(&mask_email(&1, viewer_role, viewer_account_id))
  end

  defp active_participant?(%Project{id: id}, hosted_identity_id),
    do: not is_nil(active_participant(id, hosted_identity_id))

  defp active_participant?(project_id, hosted_identity_id) when is_binary(project_id),
    do: not is_nil(active_participant(project_id, hosted_identity_id))

  defp active_participant?(_project, _hosted_identity_id), do: false

  defp member_entries(project) do
    profiles =
      ProjectMemberProfile
      |> where([p], p.project_id == ^project.id and p.state == "active")
      |> order_by([p], asc: p.role, asc: p.display_name)
      |> Repo.all()

    emails = verified_emails(Enum.map(profiles, & &1.account_id))

    Enum.map(profiles, fn profile ->
      %{
        role: String.to_existing_atom(profile.role),
        display_name: profile.display_name,
        account_id: profile.account_id,
        email: Map.get(emails, profile.account_id)
      }
    end)
  end

  defp verified_emails(account_ids) do
    ExternalIdentity
    |> join(:inner, [e], h in HostedIdentity, on: e.hosted_identity_id == h.id)
    |> where([e, h], h.account_id in ^account_ids and e.provider == "email")
    |> select([e, h], {h.account_id, e.display_identifier})
    |> Repo.all()
    |> Map.new()
  end

  # Membership management needs addresses; collaboration does not.
  defp mask_email(entry, :owner, _viewer_account_id), do: entry

  defp mask_email(entry, :participant, viewer_account_id) do
    if entry.account_id == viewer_account_id, do: entry, else: %{entry | email: nil}
  end

  @doc """
  Reports whether the immutable owner already has a project display profile.

  This is presentation state, not authorization or a precondition for any
  action: a hosted project receives the owner label at registration, and the
  invitation action surfaces that label for correction rather than requiring it.
  """
  @spec owner_profile_established?(Ecto.UUID.t()) :: boolean()
  def owner_profile_established?(project_id), do: not is_nil(owner_profile(project_id))

  @doc """
  Creates or renames the owner's own project display name.

  Only the immutable owner may run this action, and it changes the presentation
  label alone: project ownership, workspace, and account identity never move.
  """
  @spec save_owner_profile(Project.t() | Ecto.UUID.t(), Ecto.UUID.t() | nil, term()) ::
          {:ok, ProjectMemberProfile.t()} | {:error, :unauthorized | Ecto.Changeset.t()}
  def save_owner_profile(project, account_id, display_name) do
    with {:ok, owner} <- authorize_owner(project, account_id) do
      owner.project_id
      |> owner_profile()
      |> upsert_owner_profile(owner, display_name)
    end
  end

  @doc """
  The initial project display name for the owner of a hosted project.

  The owner's GitHub login is the handle they already registered the project
  under, so it is a truthful starting label rather than an invented one. Their
  email address is never used and never derived from, and an absent or
  unusable login falls back to the neutral role label instead of failing
  registration or writing nothing.
  """
  @spec initial_owner_display_name(Ecto.UUID.t()) :: String.t()
  def initial_owner_display_name(account_id) do
    with %{login: login} <- Accounts.get_github_identity(account_id),
         {:ok, %{display_name: display_name}} <- DisplayName.normalize(login) do
      display_name
    else
      _other -> @default_owner_display_name
    end
  end

  @doc """
  Builds the insert for the owner's initial project display profile.

  Project registration composes this into its own transaction, so a hosted
  project and the owner label that presents it commit together or not at all.
  The project is new, so it holds no other member profile and the label cannot
  collide; a collision would be a broken invariant and correctly aborts the
  registration rather than being papered over with an automatic suffix.
  """
  @spec initial_owner_profile_changeset(Ecto.UUID.t(), Ecto.UUID.t()) :: Ecto.Changeset.t()
  def initial_owner_profile_changeset(project_id, account_id) do
    owner_profile_changeset(project_id, account_id, initial_owner_display_name(account_id))
  end

  @doc """
  Renames one member's own project display name.

  Each current member may change only their own label. The change is
  presentation only: the stable participant identity, the account link, and the
  role never move with it, and a conflicting label is rejected for correction
  rather than given an automatic suffix.
  """
  @spec rename_member_profile(
          Project.t() | Ecto.UUID.t(),
          Ecto.UUID.t() | nil,
          Ecto.UUID.t() | nil,
          term()
        ) ::
          {:ok, ProjectMemberProfile.t()} | {:error, :unauthorized | Ecto.Changeset.t()}
  def rename_member_profile(project, account_id, hosted_identity_id, display_name) do
    with {:ok, role} <- member_role(project, account_id, hosted_identity_id),
         %ProjectMemberProfile{} = profile <- own_profile(project, role, account_id) do
      profile
      |> ProjectMemberProfile.rename_changeset(%{display_name: display_name})
      |> Repo.update()
    else
      _other -> {:error, :unauthorized}
    end
  end

  @doc """
  Preserves one departing member's last accepted label as historical attribution.

  The profile row and its label survive so prior contributions stay readable;
  only the interactive membership ends. Rights-driven anonymization removes the
  remaining account link separately.
  """
  @spec preserve_historical_label(Ecto.UUID.t(), Ecto.UUID.t() | nil) ::
          {:ok, String.t() | nil} | {:error, Ecto.Changeset.t()}
  def preserve_historical_label(project_id, account_id) do
    case member_profile(project_id, account_id) do
      nil ->
        {:ok, nil}

      profile ->
        profile
        |> ProjectMemberProfile.historical_changeset()
        |> Repo.update()
        |> case do
          {:ok, historical} -> {:ok, historical.display_name}
          {:error, changeset} -> {:error, changeset}
        end
    end
  end

  @doc """
  The label that replaces a departed member's name once it may no longer
  identify them.
  """
  @spec anonymous_member_label() :: String.t()
  def anonymous_member_label, do: ProjectMemberProfile.anonymous_label()

  @doc """
  Decides whether one member's project label must keep identifying a person.

  While participation is active the label is the member's current name and the
  question does not arise. After departure the last accepted label is retained
  only while project accountability still needs it, and that need is not a
  timer: it is the unacknowledged revocation handoff. Until a consumer has
  claimed and acknowledged the departure it has not yet cleared the departed
  person's responsibility, so the project cannot yet say who held it without
  naming them. Once every handoff for that person is acknowledged the label has
  no remaining accountability purpose and identification becomes unnecessary.
  """
  @spec attribution_necessity(ProjectMemberProfile.t()) ::
          {:necessary, :active_participation | :pending_consumer_handoff}
          | {:unnecessary, :accountability_complete | :already_anonymized}
  def attribution_necessity(%ProjectMemberProfile{state: "anonymized"}),
    do: {:unnecessary, :already_anonymized}

  def attribution_necessity(%ProjectMemberProfile{state: "active"}),
    do: {:necessary, :active_participation}

  def attribution_necessity(%ProjectMemberProfile{} = profile) do
    if pending_handoff?(profile.project_id, profile.account_id) do
      {:necessary, :pending_consumer_handoff}
    else
      {:unnecessary, :accountability_complete}
    end
  end

  @doc """
  Decides necessity for the member one account currently holds in a project.

  An anonymized profile is unreachable here by design: anonymization removes the
  account link, so there is no longer an account whose attribution could be
  looked up. That absence is the removal, not a missing record.
  """
  @spec attribution_necessity(Ecto.UUID.t(), Ecto.UUID.t() | nil) ::
          {:necessary, :active_participation | :pending_consumer_handoff}
          | {:unnecessary, :accountability_complete | :already_anonymized}
          | {:error, :not_found}
  def attribution_necessity(project_id, account_id) do
    case member_profile(project_id, account_id) do
      nil -> {:error, :not_found}
      profile -> attribution_necessity(profile)
    end
  end

  @doc """
  Removes one departed member's account link and anonymizes their project label.

  The profile row itself survives with its identifier, project, and role intact,
  so every contribution that attributes through it stays readable and
  referentially whole; only the part that identified a person is replaced. The
  same replacement reaches this specification's own derived copy of that label,
  the revocation handoff, in the same transaction, so no record left behind
  still carries the departed name or account.

  A current participant is refused. Their label is not historical attribution
  but their present name, and the members list and project-unique display-name
  rule depend on it. A verified erasure request for a current participant is
  served by ending that participation first and anonymizing afterwards.
  """
  @spec anonymize_member_attribution(Ecto.UUID.t(), Ecto.UUID.t() | nil, DateTime.t()) ::
          {:ok, %{profile: ProjectMemberProfile.t(), derived_revocations: non_neg_integer()}}
          | {:error, :not_found | :active_participation | Ecto.Changeset.t()}
  def anonymize_member_attribution(project_id, account_id, now \\ DateTime.utc_now()) do
    case member_profile(project_id, account_id) do
      nil ->
        {:error, :not_found}

      %ProjectMemberProfile{state: "active"} ->
        {:error, :active_participation}

      profile ->
        anonymize_profile(profile, DateTime.truncate(now, :second))
    end
  end

  @doc """
  Anonymizes every remaining identifiable departed label in one project.

  An approved project-deletion event ends the project's accountability purpose
  for all of its history at once, so each departed label loses its account link
  together rather than one verified request at a time. Dropping the project row
  itself removes these records outright through their own cascade; this is the
  path for a deletion workflow that retires the project while its history is
  still being wound down.
  """
  @spec anonymize_project_attribution(Ecto.UUID.t(), DateTime.t()) ::
          {:ok, %{profiles: non_neg_integer(), derived_revocations: non_neg_integer()}}
  def anonymize_project_attribution(project_id, now \\ DateTime.utc_now()) do
    anonymized_at = DateTime.truncate(now, :second)
    label = ProjectMemberProfile.anonymous_label()

    Multi.new()
    |> Multi.update_all(
      :profiles,
      from(p in ProjectMemberProfile,
        where: p.project_id == ^project_id and p.state == "historical"
      ),
      set: [
        state: "anonymized",
        account_id: nil,
        display_name: label,
        display_name_key: DisplayName.key(label),
        anonymized_at: anonymized_at,
        updated_at: anonymized_at
      ]
    )
    |> Multi.update_all(
      :derived_revocations,
      from(r in ParticipationRevocation,
        where: r.project_id == ^project_id and not is_nil(r.former_account_id)
      ),
      set: anonymized_handoff_fields(label, anonymized_at)
    )
    |> Repo.transaction()
    |> case do
      {:ok, %{profiles: {profiles, _}, derived_revocations: {derived, _}}} ->
        {:ok, %{profiles: profiles, derived_revocations: derived}}
    end
  end

  defp anonymize_profile(profile, anonymized_at) do
    Multi.new()
    |> Multi.update(
      :profile,
      ProjectMemberProfile.anonymization_changeset(profile, anonymized_at)
    )
    |> Multi.update_all(
      :derived_revocations,
      from(r in ParticipationRevocation,
        where: r.project_id == ^profile.project_id and r.former_account_id == ^profile.account_id
      ),
      set: anonymized_handoff_fields(ProjectMemberProfile.anonymous_label(), anonymized_at)
    )
    |> Repo.transaction()
    |> case do
      {:ok, %{profile: anonymized, derived_revocations: {derived, _}}} ->
        {:ok, %{profile: anonymized, derived_revocations: derived}}

      {:error, _step, changeset, _changes} ->
        {:error, changeset}
    end
  end

  # The handoff keeps its identifier, project, participant reference, reason,
  # time, and contract version so a consumer that has not finished reading it
  # still sees the same event; only the two fields that named a person change.
  defp anonymized_handoff_fields(label, anonymized_at) do
    [
      last_display_name: label,
      former_account_id: nil,
      former_hosted_identity_id: nil,
      updated_at: anonymized_at
    ]
  end

  defp pending_handoff?(_project_id, nil), do: false

  defp pending_handoff?(project_id, account_id) do
    ParticipationRevocation
    |> where(
      [r],
      r.project_id == ^project_id and r.former_account_id == ^account_id and
        is_nil(r.acknowledged_at)
    )
    |> Repo.exists?()
  end

  defp own_profile(project, :owner, _account_id), do: owner_profile(project_id(project))

  defp own_profile(project, :participant, account_id),
    do: member_profile(project_id(project), account_id)

  defp project_id(%Project{id: id}), do: id
  defp project_id(project_id) when is_binary(project_id), do: project_id

  defp authorize_owner(project, account_id) do
    case owner(project) do
      {:ok, %{account_id: ^account_id} = owner} when not is_nil(account_id) -> {:ok, owner}
      _other -> {:error, :unauthorized}
    end
  end

  defp upsert_owner_profile(nil, owner, display_name) do
    owner.project_id
    |> owner_profile_changeset(owner.account_id, display_name)
    |> Repo.insert()
  end

  defp upsert_owner_profile(profile, _owner, display_name) do
    profile
    |> ProjectMemberProfile.rename_changeset(%{display_name: display_name})
    |> Repo.update()
  end

  # The single shape of an owner-profile insert, shared by the owner's own
  # self-edit and by registration, so both write the same row the same way.
  defp owner_profile_changeset(project_id, account_id, display_name) do
    ProjectMemberProfile.changeset(%ProjectMemberProfile{}, %{
      project_id: project_id,
      account_id: account_id,
      role: "owner",
      display_name: display_name
    })
  end

  defp get_project(project_id) when is_binary(project_id) do
    Repo.get(Project, project_id)
  rescue
    Ecto.Query.CastError -> nil
  end

  defp get_project(_project_id), do: nil

  defp owner_for(%Project{storage_mode: "hosted"} = project) do
    PersonalWorkspace
    |> where([w], w.id == ^project.workspace_id)
    |> select([w], w.account_id)
    |> Repo.one()
    |> case do
      nil ->
        {:error, :not_hosted_project}

      account_id ->
        {:ok,
         %{project_id: project.id, workspace_id: project.workspace_id, account_id: account_id}}
    end
  end

  defp owner_for(%Project{}), do: {:error, :not_hosted_project}
end
