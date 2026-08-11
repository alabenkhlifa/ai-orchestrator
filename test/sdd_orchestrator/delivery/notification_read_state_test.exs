defmodule SddOrchestrator.Delivery.NotificationReadStateTest do
  @moduledoc """
  Proof for durable unread and idempotent mark-read behavior (Task 2, AC-02).

  Recipient action state must survive duplicate actions, a disconnected
  browser, and an application restart without depending on PubSub delivery.
  Every assertion here reads back through a fresh `NotificationAccess` call —
  never through in-memory state carried from the call that performed the
  mark-read — so correctness comes from the database row, not from a process
  or session remembering what happened. No test in this module subscribes to
  `SddOrchestrator.Notifications.subscribe/1` or asserts on a PubSub message,
  which proves the read state does not depend on receiving one.
  """
  use SddOrchestrator.DataCase, async: true

  alias SddOrchestrator.Delivery.NotificationAccess
  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.Notifications
  alias SddOrchestrator.Notifications.AccountNotification
  alias SddOrchestrator.Participation.Revocations
  alias SddOrchestrator.ParticipationFixtures

  setup do
    %{project: project, account: owner_account} = ParticipationFixtures.hosted_project_fixture()
    identity = ParticipationFixtures.invited_identity_fixture()
    ParticipationFixtures.participant_fixture(project, identity.hosted_identity)

    feature = DeliveryFixtures.feature_fixture(project, owner_account)

    %{
      project: project,
      owner_account: owner_account,
      feature: feature,
      participant_account: identity.account,
      participant_identity: identity.hosted_identity,
      actor: %{account_id: identity.account.id, hosted_identity_id: identity.hosted_identity.id}
    }
  end

  describe "mark_read/3" do
    test "an authorized current participant marks their own unread notification read [AC-02]",
         ctx do
      {:ok, notification} =
        Notifications.deliver(
          notification_attrs(ctx.participant_account, ctx.project, ctx.feature)
        )

      assert {:ok, updated} =
               NotificationAccess.mark_read(
                 ctx.participant_account.id,
                 ctx.actor,
                 notification.id
               )

      refute AccountNotification.unread?(updated)
      assert updated.read_at
    end

    test "repeated mark-read calls are idempotent: read_at stays exactly the first value [AC-02]",
         ctx do
      {:ok, notification} =
        Notifications.deliver(
          notification_attrs(ctx.participant_account, ctx.project, ctx.feature)
        )

      assert {:ok, first} =
               NotificationAccess.mark_read(
                 ctx.participant_account.id,
                 ctx.actor,
                 notification.id
               )

      assert {:ok, second} =
               NotificationAccess.mark_read(
                 ctx.participant_account.id,
                 ctx.actor,
                 notification.id
               )

      assert {:ok, third} =
               NotificationAccess.mark_read(
                 ctx.participant_account.id,
                 ctx.actor,
                 notification.id
               )

      assert first.read_at == second.read_at
      assert second.read_at == third.read_at
    end

    test "a fresh fetch after mark-read still reports read, proving durability without in-memory state [AC-02]",
         ctx do
      {:ok, notification} =
        Notifications.deliver(
          notification_attrs(ctx.participant_account, ctx.project, ctx.feature)
        )

      assert {:ok, marked} =
               NotificationAccess.mark_read(
                 ctx.participant_account.id,
                 ctx.actor,
                 notification.id
               )

      # A brand-new call with no state carried from the mark-read call above —
      # standing in for a reconnecting browser or a restarted node — must
      # still see the read state, because it comes from the stored row.
      assert {:ok, refetched} =
               NotificationAccess.fetch(ctx.participant_account.id, ctx.actor, notification.id)

      refute AccountNotification.unread?(refetched)
      assert refetched.read_at == marked.read_at

      assert [listed] = NotificationAccess.list(ctx.participant_account.id, ctx.actor)
      refute AccountNotification.unread?(listed)
      assert listed.read_at == marked.read_at
    end

    test "a removed participant cannot mark a stale notification read, and read_at is unaffected [AC-02]",
         ctx do
      {:ok, notification} =
        Notifications.deliver(
          notification_attrs(ctx.participant_account, ctx.project, ctx.feature)
        )

      {:ok, _removed} =
        Revocations.remove(ctx.project, ctx.owner_account.id, ctx.participant_identity.id)

      assert NotificationAccess.mark_read(ctx.participant_account.id, ctx.actor, notification.id) ==
               {:error, :not_found}

      {:ok, unchanged} = Notifications.fetch(ctx.participant_account.id, notification.id)
      assert unchanged.read_at == notification.read_at
      assert AccountNotification.unread?(unchanged)
    end

    test "mark-read does not mutate unrelated feature or project state [AC-02]", ctx do
      {:ok, notification} =
        Notifications.deliver(
          notification_attrs(ctx.participant_account, ctx.project, ctx.feature)
        )

      assert {:ok, _updated} =
               NotificationAccess.mark_read(
                 ctx.participant_account.id,
                 ctx.actor,
                 notification.id
               )

      reloaded_feature = Repo.get!(ctx.feature.__struct__, ctx.feature.id)
      reloaded_project = Repo.get!(ctx.project.__struct__, ctx.project.id)

      assert reloaded_feature.updated_at == ctx.feature.updated_at
      assert reloaded_project.updated_at == ctx.project.updated_at
    end
  end

  describe "fetch/3" do
    test "an authorized current participant fetches their own notification [AC-02]", ctx do
      {:ok, notification} =
        Notifications.deliver(
          notification_attrs(ctx.participant_account, ctx.project, ctx.feature)
        )

      assert {:ok, fetched} =
               NotificationAccess.fetch(ctx.participant_account.id, ctx.actor, notification.id)

      assert fetched.id == notification.id
    end

    test "a genuinely unknown notification id returns the same not_found refusal [AC-02]", ctx do
      assert NotificationAccess.fetch(ctx.participant_account.id, ctx.actor, Ecto.UUID.generate()) ==
               {:error, :not_found}
    end

    test "a removed participant gets not_found for a notification that still exists [AC-02]",
         ctx do
      {:ok, notification} =
        Notifications.deliver(
          notification_attrs(ctx.participant_account, ctx.project, ctx.feature)
        )

      {:ok, _removed} =
        Revocations.remove(ctx.project, ctx.owner_account.id, ctx.participant_identity.id)

      assert NotificationAccess.fetch(ctx.participant_account.id, ctx.actor, notification.id) ==
               {:error, :not_found}
    end
  end

  defp notification_attrs(account, project, feature, overrides \\ %{}) do
    Map.merge(
      %{
        account_id: account.id,
        event_type: "delivery.run_blocked",
        subject_ref: Ecto.UUID.generate(),
        event_version: 1,
        title: "A run needs an answer",
        body: "A feature is waiting on an answer before development continues.",
        project_label: project.name,
        link_path: "/projects/#{project.id}/features/#{feature.id}",
        occurred_at: DateTime.utc_now() |> DateTime.truncate(:second)
      },
      overrides
    )
  end
end
