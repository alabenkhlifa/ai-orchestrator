defmodule SddOrchestrator.Participation.Revocations do
  @moduledoc """
  Ending one participation and publishing its consumer handoff.

  Owner removal and participant self-leave share one transaction: lock the
  active authorization, mark it departed, preserve the last accepted project
  label as historical attribution, and insert exactly one versioned
  `ParticipationRevocation`. Authorization ends the moment that transaction
  commits, because every capability decision re-reads current participation.

  This module never touches another specification's records. Consumers claim
  and acknowledge the handoff and apply their own behavior — clearing
  assignment, routing pending responsibility to the owner, and keeping an
  active run under owner control.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias SddOrchestrator.Accounts.{ExternalIdentity, HostedIdentity}
  alias SddOrchestrator.Notifications
  alias SddOrchestrator.Participation

  alias SddOrchestrator.Participation.{
    EmailDelivery,
    ParticipationRevocation,
    ProjectNotifications,
    ProjectParticipant
  }

  alias SddOrchestrator.Projects.Project
  alias SddOrchestrator.Repo

  @type revoke_error :: :unauthorized | :not_a_participant | :owner_cannot_leave

  @doc """
  Removes one active participant at the immutable owner's request.
  """
  @spec remove(
          Project.t() | Ecto.UUID.t(),
          Ecto.UUID.t() | nil,
          Ecto.UUID.t() | nil,
          DateTime.t()
        ) ::
          {:ok, %{participant: ProjectParticipant.t(), revocation: ParticipationRevocation.t()}}
          | {:error, revoke_error()}
  def remove(project, owner_account_id, hosted_identity_id, now \\ DateTime.utc_now()) do
    with {:ok, project, owner} <- authorize_owner(project, owner_account_id),
         {:ok, result} <- end_participation(project, owner, hosted_identity_id, "removed", now) do
      send_removal_email(project, result.revocation, hosted_identity_id)
      {:ok, result}
    end
  end

  @doc """
  Ends the acting participant's own participation.

  The immutable owner cannot leave their own project.
  """
  @spec leave(Project.t() | Ecto.UUID.t(), Ecto.UUID.t() | nil, Ecto.UUID.t() | nil, DateTime.t()) ::
          {:ok, %{participant: ProjectParticipant.t(), revocation: ParticipationRevocation.t()}}
          | {:error, revoke_error()}
  def leave(project, account_id, hosted_identity_id, now \\ DateTime.utc_now()) do
    with {:ok, project} <- resolve_project(project),
         {:ok, owner} <- project_owner(project),
         :ok <- refuse_owner_leave(owner, account_id) do
      end_participation(project, owner, hosted_identity_id, "left", now)
    end
  end

  @doc "Lists handoffs a consumer has not acknowledged yet, oldest first."
  @spec pending(keyword()) :: [ParticipationRevocation.t()]
  def pending(opts \\ []) do
    ParticipationRevocation
    |> where([r], is_nil(r.acknowledged_at))
    |> then(&maybe_project_scope(&1, Keyword.get(opts, :project_id)))
    |> order_by([r], asc: r.occurred_at, asc: r.id)
    |> limit(^Keyword.get(opts, :limit, 100))
    |> Repo.all()
  end

  @doc """
  Claims unacknowledged handoffs for one consumer pass.

  Claiming is a delivery marker, not a lock on correctness: a consumer that
  crashes before acknowledging simply sees the same handoff again, and its own
  idempotent handling absorbs the repeat.
  """
  @spec claim(keyword()) :: [ParticipationRevocation.t()]
  def claim(opts \\ []) do
    now = opts |> Keyword.get(:now, DateTime.utc_now()) |> DateTime.truncate(:second)

    opts
    |> pending()
    |> Enum.map(fn revocation ->
      {:ok, claimed} =
        revocation |> ParticipationRevocation.claim_changeset(now) |> Repo.update()

      claimed
    end)
  end

  @doc "Records that one consumer committed its handling of a handoff."
  @spec acknowledge(Ecto.UUID.t(), String.t(), DateTime.t()) ::
          {:ok, ParticipationRevocation.t()} | {:error, :not_found}
  def acknowledge(revocation_id, consumer_ref, now \\ DateTime.utc_now()) do
    now = DateTime.truncate(now, :second)

    Repo.transaction(fn ->
      case claim_revocation(revocation_id) do
        nil ->
          Repo.rollback(:not_found)

        %ParticipationRevocation{acknowledged_at: %DateTime{}} = acknowledged ->
          ensure_identity_released(acknowledged)

        revocation ->
          revocation
          |> ParticipationRevocation.acknowledge_changeset(consumer_ref, now)
          |> Repo.update()
          |> case do
            {:ok, updated} -> updated
            {:error, _changeset} -> Repo.rollback(:not_found)
          end
      end
    end)
    |> case do
      {:ok, acknowledged} -> {:ok, acknowledged}
      {:error, _reason} -> {:error, :not_found}
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_found}
  end

  defp claim_revocation(revocation_id) do
    ParticipationRevocation
    |> where([r], r.id == ^revocation_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp ensure_identity_released(
         %ParticipationRevocation{
           former_hosted_identity_id: nil,
           former_account_id: nil
         } = acknowledged
       ),
       do: acknowledged

  defp ensure_identity_released(acknowledged) do
    acknowledged
    |> ParticipationRevocation.identity_release_changeset()
    |> Repo.update()
    |> case do
      {:ok, released} -> released
      {:error, _changeset} -> Repo.rollback(:not_found)
    end
  end

  defp end_participation(project, owner, hosted_identity_id, reason, now) do
    now = DateTime.truncate(now, :second)

    Multi.new()
    |> Multi.run(:participant, fn repo, _changes ->
      claim_active(repo, project.id, hosted_identity_id)
    end)
    |> Multi.update(:departed, fn %{participant: participant} ->
      ProjectParticipant.departure_changeset(participant, %{
        departure_reason: reason,
        departed_at: now
      })
    end)
    |> Multi.run(:last_display_name, fn _repo, %{participant: participant} ->
      Participation.preserve_historical_label(project.id, account_id_of(participant))
    end)
    |> Multi.insert(:revocation, fn changes ->
      ParticipationRevocation.changeset(%ParticipationRevocation{}, %{
        project_id: project.id,
        project_participant_id: changes.participant.id,
        former_hosted_identity_id: changes.participant.hosted_identity_id,
        former_account_id: account_id_of(changes.participant),
        owner_account_id: owner.account_id,
        last_display_name: changes.last_display_name,
        reason: reason,
        occurred_at: now
      })
    end)
    |> Multi.merge(fn %{revocation: revocation} ->
      notify(project, revocation)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{departed: departed, revocation: revocation}} ->
        {:ok, %{participant: departed, revocation: revocation}}

      {:error, :participant, reason, _changes} ->
        {:error, reason}

      {:error, _step, _reason, _changes} ->
        {:error, :not_a_participant}
    end
  end

  # The removal message goes to the address currently verified for that stable
  # identity. It is sent after the authoritative transaction commits, so a
  # provider outage leaves a recorded failure rather than an uncommitted removal.
  defp send_removal_email(project, revocation, hosted_identity_id) do
    case verified_address(hosted_identity_id) do
      nil ->
        :ok

      address ->
        EmailDelivery.deliver(:participant_removed, %{
          subject_ref: revocation.id,
          event_version: revocation.contract_version,
          recipient: address,
          project_label: project.name
        })
    end
  end

  defp verified_address(hosted_identity_id) when is_binary(hosted_identity_id) do
    ExternalIdentity
    |> join(:inner, [e], h in HostedIdentity, on: e.hosted_identity_id == h.id)
    |> where([e, h], h.id == ^hosted_identity_id and e.provider == "email")
    |> select([e, _h], e.display_identifier)
    |> limit(1)
    |> Repo.one()
  rescue
    Ecto.Query.CastError -> nil
  end

  defp verified_address(_hosted_identity_id), do: nil

  # Removal reaches the former participant at their account boundary, where the
  # record stays readable after project access ends. Leaving reaches the owner.
  defp notify(project, %ParticipationRevocation{reason: "removed"} = revocation) do
    if revocation.former_account_id do
      Multi.insert(
        Multi.new(),
        :notification,
        Notifications.changeset(ProjectNotifications.removal_event(project, revocation)),
        Notifications.insert_options()
      )
    else
      Multi.new()
    end
  end

  defp notify(project, %ParticipationRevocation{reason: "left"} = revocation) do
    Multi.insert(
      Multi.new(),
      :notification,
      Notifications.changeset(ProjectNotifications.leave_event(project, revocation)),
      Notifications.insert_options()
    )
  end

  defp claim_active(repo, project_id, hosted_identity_id) when is_binary(hosted_identity_id) do
    ProjectParticipant
    |> where(
      [p],
      p.project_id == ^project_id and p.hosted_identity_id == ^hosted_identity_id and
        p.state == "active"
    )
    |> lock("FOR UPDATE")
    |> repo.one()
    |> case do
      nil -> {:error, :not_a_participant}
      participant -> {:ok, participant}
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_a_participant}
  end

  defp claim_active(_repo, _project_id, _hosted_identity_id), do: {:error, :not_a_participant}

  defp account_id_of(%ProjectParticipant{hosted_identity_id: nil}), do: nil

  defp account_id_of(%ProjectParticipant{hosted_identity_id: hosted_identity_id}) do
    SddOrchestrator.Accounts.HostedIdentity
    |> where([h], h.id == ^hosted_identity_id)
    |> select([h], h.account_id)
    |> Repo.one()
  end

  defp authorize_owner(project, account_id) do
    with {:ok, project} <- resolve_project(project),
         {:ok, owner} <- project_owner(project) do
      if not is_nil(account_id) and owner.account_id == account_id do
        {:ok, project, owner}
      else
        {:error, :unauthorized}
      end
    end
  end

  defp refuse_owner_leave(owner, account_id) do
    if not is_nil(account_id) and owner.account_id == account_id,
      do: {:error, :owner_cannot_leave},
      else: :ok
  end

  defp resolve_project(%Project{} = project), do: {:ok, project}

  defp resolve_project(project_id) when is_binary(project_id) do
    case Repo.get(Project, project_id) do
      nil -> {:error, :unauthorized}
      project -> {:ok, project}
    end
  rescue
    Ecto.Query.CastError -> {:error, :unauthorized}
  end

  defp resolve_project(_project), do: {:error, :unauthorized}

  defp project_owner(project) do
    case Participation.owner(project) do
      {:ok, owner} -> {:ok, owner}
      {:error, _reason} -> {:error, :unauthorized}
    end
  end

  defp maybe_project_scope(query, nil), do: query
  defp maybe_project_scope(query, project_id), do: where(query, [r], r.project_id == ^project_id)
end
