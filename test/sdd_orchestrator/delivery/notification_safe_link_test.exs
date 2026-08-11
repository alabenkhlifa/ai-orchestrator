defmodule SddOrchestrator.Delivery.NotificationSafeLinkTest do
  @moduledoc """
  Proof for safe, non-disclosing notification-link access (Task 3, AC-03).

  A participant who opens a notification's safe feature link must land on the
  related feature, and an unknown, cross-project, or removed participant must
  receive a non-disclosing refusal — the identical `{:error, :not_found}` no
  matter which of those cases occurred. `resolve_safe_link/3` layers
  `Features.fetch/3`'s own project-scoped feature lookup on top of
  `fetch/3`'s notification-level authorization, so a `link_path` whose feature
  id genuinely belongs to a different project is caught even when the parsed
  project id itself is one the actor currently belongs to.
  """
  use SddOrchestrator.DataCase, async: true

  alias SddOrchestrator.Delivery.NotificationAccess
  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.Notifications
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

  describe "resolve_safe_link/3" do
    test "a current participant resolves their own notification's safe link [AC-03]", ctx do
      {:ok, notification} =
        Notifications.deliver(
          notification_attrs(ctx.participant_account, ctx.project, ctx.feature)
        )

      assert NotificationAccess.resolve_safe_link(
               ctx.participant_account.id,
               ctx.actor,
               notification.id
             ) == {:ok, notification.link_path}
    end

    test "a removed former participant gets not_found for a link that used to resolve [AC-03]",
         ctx do
      {:ok, notification} =
        Notifications.deliver(
          notification_attrs(ctx.participant_account, ctx.project, ctx.feature)
        )

      {:ok, _removed} =
        Revocations.remove(ctx.project, ctx.owner_account.id, ctx.participant_identity.id)

      assert NotificationAccess.resolve_safe_link(
               ctx.participant_account.id,
               ctx.actor,
               notification.id
             ) == {:error, :not_found}
    end

    test "an unknown notification id gets not_found [AC-03]", ctx do
      assert NotificationAccess.resolve_safe_link(
               ctx.participant_account.id,
               ctx.actor,
               Ecto.UUID.generate()
             ) == {:error, :not_found}
    end

    test "a notification for a project the account was never part of gets not_found [AC-03]",
         ctx do
      other = ParticipationFixtures.hosted_project_fixture()
      other_feature = DeliveryFixtures.feature_fixture(other.project, other.account)

      {:ok, notification} =
        Notifications.deliver(
          notification_attrs(ctx.participant_account, other.project, other_feature)
        )

      assert NotificationAccess.resolve_safe_link(
               ctx.participant_account.id,
               ctx.actor,
               notification.id
             ) == {:error, :not_found}
    end

    test "a malformed link_path gets not_found without crashing [AC-03]", ctx do
      {:ok, notification} =
        Notifications.deliver(
          notification_attrs(ctx.participant_account, ctx.project, ctx.feature, %{
            link_path: "/dashboard"
          })
        )

      assert NotificationAccess.resolve_safe_link(
               ctx.participant_account.id,
               ctx.actor,
               notification.id
             ) == {:error, :not_found}
    end

    test "a feature id that does not genuinely belong to the parsed project gets not_found [AC-03]",
         ctx do
      other = ParticipationFixtures.hosted_project_fixture()
      other_feature = DeliveryFixtures.feature_fixture(other.project, other.account)

      # A hand-built link: a real project the actor currently belongs to,
      # spliced with a real feature id that actually belongs to a different
      # project. `project_id` alone would authorize this; only
      # `Features.fetch/3`'s project-scoped lookup catches it.
      spliced_link_path = "/projects/#{ctx.project.id}/features/#{other_feature.id}"

      {:ok, notification} =
        Notifications.deliver(
          notification_attrs(ctx.participant_account, ctx.project, ctx.feature, %{
            link_path: spliced_link_path
          })
        )

      assert NotificationAccess.resolve_safe_link(
               ctx.participant_account.id,
               ctx.actor,
               notification.id
             ) == {:error, :not_found}
    end

    test "removed, unknown, and cross-project all return the textually identical refusal [AC-03]",
         ctx do
      {:ok, removed_source} =
        Notifications.deliver(
          notification_attrs(ctx.participant_account, ctx.project, ctx.feature)
        )

      {:ok, _removed} =
        Revocations.remove(ctx.project, ctx.owner_account.id, ctx.participant_identity.id)

      removed_result =
        NotificationAccess.resolve_safe_link(
          ctx.participant_account.id,
          ctx.actor,
          removed_source.id
        )

      unknown_result =
        NotificationAccess.resolve_safe_link(
          ctx.participant_account.id,
          ctx.actor,
          Ecto.UUID.generate()
        )

      other = ParticipationFixtures.hosted_project_fixture()
      other_feature = DeliveryFixtures.feature_fixture(other.project, other.account)

      {:ok, cross_project_source} =
        Notifications.deliver(
          notification_attrs(ctx.participant_account, other.project, other_feature)
        )

      cross_project_result =
        NotificationAccess.resolve_safe_link(
          ctx.participant_account.id,
          ctx.actor,
          cross_project_source.id
        )

      assert removed_result == {:error, :not_found}
      assert unknown_result == {:error, :not_found}
      assert cross_project_result == {:error, :not_found}
      assert removed_result == unknown_result
      assert unknown_result == cross_project_result
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
