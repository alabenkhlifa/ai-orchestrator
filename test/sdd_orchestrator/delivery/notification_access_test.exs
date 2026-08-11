defmodule SddOrchestrator.Delivery.NotificationAccessTest do
  @moduledoc """
  Proof for authorized guided-delivery notification listing (Task 1, AC-01).

  Only currently authorized records may be returned, so the list is
  revalidated against live participation on every call rather than trusting
  who a notification was originally addressed to: a departed participant, and
  an account that never belonged to the project at all, both see nothing for
  it. The list stays inside the `delivery.` namespace only — Slice 08's own
  `participation.` notifications are excluded even when they exist for the
  same account. Presentation minimization is proven at the source
  (`AccountNotificationTest`); what this module owns is that reads never
  depend on a `ProjectMemberProfile` row existing.
  """
  use SddOrchestrator.DataCase, async: true

  alias SddOrchestrator.Delivery.NotificationAccess
  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.Notifications
  alias SddOrchestrator.Notifications.AccountNotification
  alias SddOrchestrator.Participation.ProjectMemberProfile
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

  describe "list/3" do
    test "a current participant sees their own delivery notifications [AC-01]", ctx do
      {:ok, notification} =
        Notifications.deliver(
          notification_attrs(ctx.participant_account, ctx.project, ctx.feature)
        )

      assert [listed] = NotificationAccess.list(ctx.participant_account.id, ctx.actor)
      assert listed.id == notification.id
      assert listed.link_path == notification.link_path
    end

    test "a removed former participant no longer sees that project's notifications [AC-01]",
         ctx do
      {:ok, _notification} =
        Notifications.deliver(
          notification_attrs(ctx.participant_account, ctx.project, ctx.feature)
        )

      assert NotificationAccess.list(ctx.participant_account.id, ctx.actor) != []

      {:ok, _removed} =
        Revocations.remove(ctx.project, ctx.owner_account.id, ctx.participant_identity.id)

      assert NotificationAccess.list(ctx.participant_account.id, ctx.actor) == []
    end

    test "notifications for a project the account was never part of are not returned [AC-01]",
         ctx do
      other = ParticipationFixtures.hosted_project_fixture()
      other_feature = DeliveryFixtures.feature_fixture(other.project, other.account)

      {:ok, _notification} =
        Notifications.deliver(
          notification_attrs(ctx.participant_account, other.project, other_feature)
        )

      assert NotificationAccess.list(ctx.participant_account.id, ctx.actor) == []
    end

    test "participation-namespace notifications are excluded even for the same account [AC-01]",
         ctx do
      {:ok, delivery} =
        Notifications.deliver(
          notification_attrs(ctx.participant_account, ctx.project, ctx.feature)
        )

      {:ok, _participation} =
        Notifications.deliver(
          notification_attrs(ctx.participant_account, ctx.project, ctx.feature, %{
            event_type: "participation.joined",
            subject_ref: Ecto.UUID.generate(),
            link_path: "/projects/#{ctx.project.id}/participation"
          })
        )

      assert [listed] = NotificationAccess.list(ctx.participant_account.id, ctx.actor)
      assert listed.id == delivery.id
    end

    test "orders newest first [AC-01]", ctx do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, older} =
        Notifications.deliver(
          notification_attrs(ctx.participant_account, ctx.project, ctx.feature, %{
            subject_ref: "older",
            occurred_at: DateTime.add(now, -60, :second)
          })
        )

      {:ok, newer} =
        Notifications.deliver(
          notification_attrs(ctx.participant_account, ctx.project, ctx.feature, %{
            subject_ref: "newer",
            occurred_at: now
          })
        )

      assert Enum.map(NotificationAccess.list(ctx.participant_account.id, ctx.actor), & &1.id) ==
               [newer.id, older.id]
    end

    test "breaks an occurred_at tie by descending id [AC-01]", ctx do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, tied_a} =
        Notifications.deliver(
          notification_attrs(ctx.participant_account, ctx.project, ctx.feature, %{
            subject_ref: "tied-a",
            occurred_at: now
          })
        )

      {:ok, tied_b} =
        Notifications.deliver(
          notification_attrs(ctx.participant_account, ctx.project, ctx.feature, %{
            subject_ref: "tied-b",
            occurred_at: now
          })
        )

      expected = Enum.sort([tied_a.id, tied_b.id], :desc)

      assert Enum.map(NotificationAccess.list(ctx.participant_account.id, ctx.actor), & &1.id) ==
               expected
    end

    test "limits the page and clamps an oversized or invalid limit [AC-01]", ctx do
      for n <- 1..3 do
        Notifications.deliver(
          notification_attrs(ctx.participant_account, ctx.project, ctx.feature, %{
            subject_ref: "n#{n}"
          })
        )
      end

      assert length(NotificationAccess.list(ctx.participant_account.id, ctx.actor, limit: 2)) == 2

      assert length(
               NotificationAccess.list(ctx.participant_account.id, ctx.actor,
                 limit: NotificationAccess.max_limit() + 100
               )
             ) == 3

      assert length(NotificationAccess.list(ctx.participant_account.id, ctx.actor, limit: 0)) == 3

      assert length(NotificationAccess.list(ctx.participant_account.id, ctx.actor, limit: -1)) ==
               3

      assert NotificationAccess.default_limit() == 50
      assert NotificationAccess.max_limit() == 200
    end

    test "reports unread and read state through the existing schema field [AC-01]", ctx do
      {:ok, unread} =
        Notifications.deliver(
          notification_attrs(ctx.participant_account, ctx.project, ctx.feature, %{
            subject_ref: "unread"
          })
        )

      {:ok, will_be_read} =
        Notifications.deliver(
          notification_attrs(ctx.participant_account, ctx.project, ctx.feature, %{
            subject_ref: "read"
          })
        )

      {:ok, _read} = Notifications.mark_read(ctx.participant_account.id, will_be_read.id)

      listed = NotificationAccess.list(ctx.participant_account.id, ctx.actor)
      by_id = Map.new(listed, &{&1.id, &1})

      assert AccountNotification.unread?(by_id[unread.id])
      refute AccountNotification.unread?(by_id[will_be_read.id])
      assert by_id[will_be_read.id].read_at
    end

    test "drops a record whose link cannot be parsed to a project rather than crashing [AC-01]",
         ctx do
      {:ok, _notification} =
        Notifications.deliver(
          notification_attrs(ctx.participant_account, ctx.project, ctx.feature, %{
            link_path: "/dashboard"
          })
        )

      assert NotificationAccess.list(ctx.participant_account.id, ctx.actor) == []
    end

    test "a current participant with no ProjectMemberProfile row still sees their notifications [AC-01]",
         ctx do
      refute Repo.get_by(ProjectMemberProfile,
               project_id: ctx.project.id,
               account_id: ctx.participant_account.id
             )

      {:ok, notification} =
        Notifications.deliver(
          notification_attrs(ctx.participant_account, ctx.project, ctx.feature)
        )

      assert [listed] = NotificationAccess.list(ctx.participant_account.id, ctx.actor)
      assert listed.id == notification.id
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
