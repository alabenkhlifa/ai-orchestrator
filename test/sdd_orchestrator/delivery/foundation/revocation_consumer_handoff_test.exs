defmodule SddOrchestrator.Delivery.Foundation.RevocationConsumerHandoffTest do
  @moduledoc """
  Handoff proof for `capability:guided-delivery-revocation-consumer` (Task 54).

  The rights-and-anonymization continuation builds on how this slice consumed a
  departure. What it may rely on is pinned here: the consumer names itself in
  the producer's acknowledgement, acknowledges only after its own commits have
  landed, records the applied trail as an account reference with no name or
  address frozen into history, replays idempotently after a crash between claim
  and acknowledgement, and refuses an unusable authority before claiming rather
  than losing the handoff.
  """
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Delivery.{ActivityEntry, Feature, RevocationConsumer}
  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.Participation.{Boundary, ParticipationRevocation, Revocations}

  setup do
    context = DeliveryFixtures.delivery_project_fixture()
    departing = context.identity

    held =
      DeliveryFixtures.feature_fixture(context.project, departing.account, %{
        assigned_account_id: departing.account.id
      })

    %{
      authority: context.workspace,
      project: context.project,
      owner_account: context.account,
      departing: departing,
      held: held
    }
  end

  describe "the published consumer contract" do
    test "the consumer acknowledges under its own stable reference, after committing", ctx do
      assert RevocationConsumer.consumer_ref() == "feature-delivery"

      {:ok, %{revocation: revocation}} = remove(ctx)

      assert {:ok, [applied]} = RevocationConsumer.claim_and_apply(ctx.authority)
      assert applied.revocation_id == revocation.id
      assert applied.cleared_feature_ids == [ctx.held.id]

      # The delivery consequence committed, and only then was the producer told.
      assert is_nil(Repo.get!(Feature, ctx.held.id).assigned_account_id)

      acknowledged = Repo.get!(ParticipationRevocation, revocation.id)
      assert acknowledged.consumer_ref == "feature-delivery"
      assert acknowledged.acknowledged_at
      assert RevocationConsumer.pending() == []
    end

    test "the applied trail names an account reference, never a person", ctx do
      {:ok, %{revocation: revocation}} = remove(ctx)
      {:ok, _applied} = RevocationConsumer.claim_and_apply(ctx.authority)

      assert [entry] =
               Repo.all(from entry in ActivityEntry, where: entry.type == "revocation_applied")

      assert entry.feature_id == ctx.held.id
      assert entry.actor_kind == "system"
      assert entry.payload["former_account_id"] == ctx.departing.account.id
      assert entry.payload["reason"] == "removed"
      assert entry.payload["contract_version"] == revocation.contract_version

      # Anonymization can only propagate if history holds the reference and not
      # the identity: no name, no label, no address may be frozen in.
      refute Enum.any?(Map.keys(entry.payload), &(&1 in ~w(display_name name email)))

      rendered = inspect(entry.payload)
      refute rendered =~ "@"
    end

    test "a crash between claim and acknowledgement replays without a second application",
         ctx do
      {:ok, %{revocation: revocation}} = remove(ctx)

      # The crash: a consumer claimed the handoff and died before acknowledging.
      assert [claimed] = Boundary.claim_revocations()
      assert claimed.id == revocation.id

      # The next pass sees the same handoff, finds the work, applies it once.
      assert {:ok, [applied]} = RevocationConsumer.claim_and_apply(ctx.authority)
      assert applied.revocation_id == revocation.id
      assert applied.cleared_feature_ids == [ctx.held.id]

      # A further pass has nothing left to claim and clears nothing twice.
      assert {:ok, []} = RevocationConsumer.claim_and_apply(ctx.authority)

      assert Repo.aggregate(
               from(entry in ActivityEntry, where: entry.type == "revocation_applied"),
               :count
             ) == 1
    end

    test "an unusable authority is refused before the handoff is claimed", ctx do
      {:ok, %{revocation: revocation}} = remove(ctx)

      assert {:error, :unsupported_authority} = RevocationConsumer.claim_and_apply(:broken)

      # The handoff was neither lost nor acknowledged: the next real consumer
      # pass still sees it.
      assert [pending] = RevocationConsumer.pending()
      assert pending.id == revocation.id
      assert is_nil(Repo.get!(ParticipationRevocation, revocation.id).acknowledged_at)
      assert Repo.get!(Feature, ctx.held.id).assigned_account_id == ctx.departing.account.id
    end

    test "participation records are not mutated by the consumer", ctx do
      {:ok, _revoked} = remove(ctx)

      participants_before = participation_rows()
      {:ok, _applied} = RevocationConsumer.claim_and_apply(ctx.authority)

      # The producer's records are untouched apart from the acknowledgement the
      # boundary itself records; membership state belongs to Slice 08.
      assert participation_rows() == participants_before
    end
  end

  defp remove(ctx),
    do: Revocations.remove(ctx.project, ctx.owner_account.id, ctx.departing.hosted_identity.id)

  defp participation_rows do
    Repo.all(
      from participant in SddOrchestrator.Participation.ProjectParticipant,
        order_by: participant.id,
        select: {participant.id, participant.state, participant.hosted_identity_id}
    )
  end
end
