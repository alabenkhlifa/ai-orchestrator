defmodule SddOrchestrator.Delivery.Assignment do
  @moduledoc """
  Who is responsible for one feature, and how that changes.

  Two related things live here. Assignment is an editable field: any current
  participant may set `Assigned` to any current participant of the same
  project, or take it themselves. Responsibility is a derived answer: the
  current assignee if they are still a participant, otherwise the current
  creator if they still are, otherwise the project owner.

  The fallback is what makes the rest of the slice safe to build on. A blocking
  question, a review, and a notification all need a deterministic person even
  when the assignee left ten minutes ago, and asking here always returns one
  without ever naming someone who is no longer authorized.

  Identities are presented by project display name. No participant email
  reaches this module, its activity payloads, or its callers.
  """

  alias Ecto.Multi
  alias SddOrchestrator.Delivery.{Activity, Feature, ParticipantGuard}
  alias SddOrchestrator.Repo

  @type actor :: ParticipantGuard.actor()
  @type member :: ParticipantGuard.member()

  @type error :: :unauthorized | :invalid_target | :stale_state

  @doc """
  Lists the participants this feature may be assigned to.

  The selector is exactly the project's current members, so a departed person
  cannot be chosen and an outsider sees nothing at all.
  """
  @spec assignable_members(Ecto.UUID.t(), actor()) :: [member()]
  def assignable_members(project_id, actor),
    do: ParticipantGuard.current_members(project_id, actor)

  @doc """
  Assigns the feature to one current participant.

  Passing `nil` clears the assignment, which returns responsibility to the
  creator without pretending the feature is unowned.
  """
  @spec assign(Ecto.UUID.t(), actor(), Feature.t(), Ecto.UUID.t() | nil) ::
          {:ok, Feature.t()} | {:error, error()}
  def assign(project_id, actor, %Feature{} = feature, target_account_id) do
    with {:ok, member} <- ParticipantGuard.authorize_action(project_id, actor, :assign),
         :ok <- scoped?(project_id, feature),
         :ok <- assignable?(project_id, target_account_id) do
      commit(project_id, feature, member, target_account_id)
    end
  end

  @doc "Assigns the feature to the acting participant."
  @spec assign_to_me(Ecto.UUID.t(), actor(), Feature.t()) ::
          {:ok, Feature.t()} | {:error, error()}
  def assign_to_me(project_id, actor, %Feature{} = feature) do
    with {:ok, member} <- ParticipantGuard.authorize_action(project_id, actor, :assign) do
      assign(project_id, actor, feature, member.account_id)
    end
  end

  @doc "Clears the assignment."
  @spec unassign(Ecto.UUID.t(), actor(), Feature.t()) :: {:ok, Feature.t()} | {:error, error()}
  def unassign(project_id, actor, %Feature{} = feature),
    do: assign(project_id, actor, feature, nil)

  @doc """
  Resolves the current responsible participant for one feature.

  Assigned first, then creator, then the immutable owner. Each candidate must
  still be a current member, so responsibility never resolves to someone whose
  access ended.
  """
  @spec responsible(Ecto.UUID.t(), Feature.t()) :: {:ok, member()} | {:error, :unavailable}
  def responsible(project_id, %Feature{} = feature) do
    members = current_members_by_account(project_id)

    [feature.assigned_account_id, feature.creator_account_id]
    |> Enum.find_value(&Map.get(members, &1))
    |> case do
      nil -> owner_fallback(project_id)
      member -> {:ok, member}
    end
  end

  @doc """
  Presents the feature's creator and assignee by project display name.

  A person who is no longer a member has no current display name, so the label
  is `nil` and the caller renders its own neutral historical text rather than
  inventing a name or exposing an address.
  """
  @spec labels(Ecto.UUID.t(), Feature.t()) :: %{
          creator: String.t() | nil,
          assignee: String.t() | nil
        }
  def labels(project_id, %Feature{} = feature) do
    members = current_members_by_account(project_id)

    %{
      creator: display_name(members, feature.creator_account_id),
      assignee: display_name(members, feature.assigned_account_id)
    }
  end

  defp commit(project_id, feature, member, target_account_id) do
    Multi.new()
    |> Multi.update(
      :feature,
      Feature.assignment_changeset(feature, target_account_id, feature.state_version)
    )
    |> Activity.append_multi(:activity, %{
      project_id: project_id,
      feature_id: feature.id,
      actor_kind: "participant",
      actor_account_id: member.account_id,
      type: "assignment_changed",
      payload: assignment_payload(member, target_account_id)
    })
    |> Repo.transaction()
    |> case do
      {:ok, %{feature: updated}} -> {:ok, updated}
      {:error, :feature, _changeset, _changes} -> {:error, :stale_state}
      {:error, _step, _reason, _changes} -> {:error, :stale_state}
    end
  rescue
    Ecto.StaleEntryError -> {:error, :stale_state}
  end

  # The payload records what happened and to whom by account reference only.
  # Display names are resolved at render time from current participation, so a
  # later rename or departure is reflected rather than frozen into history.
  defp assignment_payload(member, nil), do: %{"action" => "unassigned", "by" => member.account_id}

  defp assignment_payload(%{account_id: account_id}, account_id),
    do: %{"action" => "self_assigned", "assigned_account_id" => account_id}

  defp assignment_payload(member, target_account_id),
    do: %{
      "action" => "assigned",
      "assigned_account_id" => target_account_id,
      "by" => member.account_id
    }

  defp assignable?(_project_id, nil), do: :ok

  defp assignable?(project_id, target_account_id) do
    project_id
    |> current_members_by_account()
    |> Map.has_key?(target_account_id)
    |> case do
      true -> :ok
      false -> {:error, :invalid_target}
    end
  end

  defp current_members_by_account(project_id) do
    project_id
    |> ParticipantGuard.owner()
    |> case do
      {:ok, _owner} -> ParticipantGuard.current_members(project_id, owner_actor(project_id))
      {:error, :unauthorized} -> []
    end
    |> Map.new(&{&1.account_id, &1})
  end

  # Membership resolution is a project-level read, not an acting-person read:
  # responsibility must resolve the same way for a background projector as for
  # a signed-in participant.
  defp owner_actor(project_id) do
    case ParticipantGuard.owner(project_id) do
      {:ok, owner} ->
        %{account_id: owner.account_id, hosted_identity_id: owner.hosted_identity_id}

      {:error, :unauthorized} ->
        %{account_id: nil, hosted_identity_id: nil}
    end
  end

  defp owner_fallback(project_id) do
    case ParticipantGuard.owner(project_id) do
      {:ok, owner} -> {:ok, owner}
      {:error, :unauthorized} -> {:error, :unavailable}
    end
  end

  defp display_name(_members, nil), do: nil

  defp display_name(members, account_id) do
    case Map.get(members, account_id) do
      nil -> nil
      member -> member.display_name
    end
  end

  defp scoped?(project_id, %Feature{project_id: project_id}), do: :ok
  defp scoped?(_project_id, %Feature{}), do: {:error, :unauthorized}
end
