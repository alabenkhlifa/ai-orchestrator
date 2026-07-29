defmodule SddOrchestrator.Delivery.RevocationConsumer do
  @moduledoc """
  What feature delivery does when someone stops being a participant.

  A departure is published by the participation specification as one versioned
  `ParticipationRevocation`, never as a write into this slice's records. This
  module is the other half of that contract: it claims the handoff, applies the
  delivery consequences under this slice's own authority, and acknowledges. It
  mutates no participation record — the handoff's acknowledgement is the single
  field it may set, and it sets it through the published boundary rather than by
  touching the table.

  Only one consequence actually needs writing. A current assignment names a
  person who can no longer act, so every feature in the project still assigned
  to the departing account is cleared. Everything else AC-30 asks for is already
  true without a write:

    * Pending blocking-question and review responsibility routes to the owner
      because `Assignment.responsible/2` derives responsibility from current
      participation on every call, and a cleared assignment plus a departed
      creator leaves the owner. Duplicating that resolution here would create a
      second answer that could drift from the one the screen shows.
    * Prior activity keeps the `actor_account_id` it was written with. History
      is append-only and is not rewritten by a departure; the last accepted
      project display name is preserved by the producer and rendered as
      non-interactive attribution.
    * The active run is not cancelled. Cancelling on departure would throw away
      work nobody decided to end; the run stays live and the owner keeps the
      authority to cancel or retry it, which is exactly why that authority is
      the owner's as well as the initiator's.
    * The former participant's access ends at `ParticipantGuard`, which re-reads
      current participation on every call. There is nothing to revoke here.

  Ordering is what makes a crash safe. Each affected feature is cleared and
  recorded in one commit, and the handoff is acknowledged only after every one
  of those commits has landed. A process that dies in between sees the same
  handoff on the next claim, finds no feature still assigned to the departed
  account, writes nothing, and acknowledges. Application is idempotent because
  the work it looks for is gone once it has been done, not because a marker says
  so.
  """

  alias SddOrchestrator.Delivery.{DeliveryStore, Feature}
  alias SddOrchestrator.Participation.Boundary
  alias SddOrchestrator.Participation.ParticipationRevocation

  # Names this consumer in the producer's acknowledgement, so a second approved
  # consumer's progress is never mistaken for ours.
  @consumer_ref "feature-delivery"

  @type authority :: DeliveryStore.authority()

  @type applied :: %{
          revocation_id: Ecto.UUID.t(),
          project_id: Ecto.UUID.t(),
          former_account_id: Ecto.UUID.t() | nil,
          cleared_feature_ids: [Ecto.UUID.t()]
        }

  @type error :: :stale_state | :unsupported_authority | :not_found | term()

  @doc "The reference this slice acknowledges departure handoffs under."
  @spec consumer_ref() :: String.t()
  def consumer_ref, do: @consumer_ref

  @doc "Lists departure handoffs this slice has not applied yet."
  @spec pending(keyword()) :: [ParticipationRevocation.t()]
  def pending(opts \\ []), do: Boundary.pending_revocations(opts)

  @doc """
  Claims every outstanding departure handoff and applies it.

  Handoffs are applied in the order the producer published them, and the pass
  stops at the first one that cannot be committed rather than acknowledging
  work that did not happen. An unacknowledged handoff is simply claimed again.
  """
  @spec claim_and_apply(authority(), keyword()) :: {:ok, [applied()]} | {:error, error()}
  def claim_and_apply(authority, opts \\ []) do
    if DeliveryStore.supported?(authority) do
      apply_claimed(authority, opts)
    else
      # An unusable authority reads as an empty project, and acknowledging a
      # departure nobody could evaluate would lose it for good. Refuse before
      # claiming, because claiming is itself a write on the producer's record.
      {:error, :unsupported_authority}
    end
  end

  defp apply_claimed(authority, opts) do
    opts
    |> Boundary.claim_revocations()
    |> Enum.reduce_while({:ok, []}, fn revocation, {:ok, acc} ->
      case apply_one(authority, revocation) do
        {:ok, result} -> {:cont, {:ok, [result | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, reason} -> {:error, reason}
    end
  end

  # The acknowledgement is deliberately the last thing to happen, and only
  # happens at all when every feature commit for this handoff has committed.
  defp apply_one(authority, revocation) do
    with {:ok, cleared} <- clear_assignments(authority, revocation),
         {:ok, _acknowledged} <- Boundary.acknowledge_revocation(revocation.id, @consumer_ref) do
      {:ok,
       %{
         revocation_id: revocation.id,
         project_id: revocation.project_id,
         former_account_id: revocation.former_account_id,
         cleared_feature_ids: cleared
       }}
    end
  end

  defp clear_assignments(authority, revocation) do
    authority
    |> held_features(revocation)
    |> Enum.reduce_while({:ok, []}, fn feature, {:ok, cleared} ->
      case commit(authority, revocation, feature) do
        {:ok, _results} -> {:cont, {:ok, [feature.id | cleared]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, cleared} -> {:ok, Enum.reverse(cleared)}
      {:error, reason} -> {:error, reason}
    end
  end

  # A departed identity that never resolved to an account holds nothing, and
  # asking the store for features assigned to `nil` would mean every unassigned
  # feature in the project.
  defp held_features(_authority, %ParticipationRevocation{former_account_id: nil}), do: []

  defp held_features(authority, revocation) do
    DeliveryStore.list_features(authority, revocation.project_id,
      assigned_account_id: revocation.former_account_id
    )
  end

  # Two records, two steps, each written exactly once. Feature and activity
  # travel together because a cleared assignment nobody can see in the history
  # is an unexplained change on somebody else's board.
  defp commit(authority, revocation, %Feature{} = feature) do
    authority
    |> DeliveryStore.commit(revocation.project_id, [
      {:feature, {:clear_assignment, feature}},
      {:activity,
       {:append_activity,
        %{
          project_id: revocation.project_id,
          feature_id: feature.id,
          actor_kind: "system",
          type: "revocation_applied",
          payload: %{
            "operation_key" => "revocation:#{revocation.id}:#{feature.id}",
            # An account reference only. The display name is resolved from
            # current participation at render time, so history is labelled
            # rather than rewritten.
            "former_account_id" => revocation.former_account_id,
            "reason" => revocation.reason,
            "contract_version" => revocation.contract_version
          }
        }}}
    ])
    |> case do
      {:ok, results} -> {:ok, results}
      {:error, _step, reason} -> {:error, reason}
    end
  end
end
