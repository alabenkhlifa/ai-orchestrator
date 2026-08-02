defmodule SddOrchestrator.Delivery.Foundation.NotificationProjectionHandoffTest do
  @moduledoc """
  Handoff proof for `capability:guided-delivery-notification-projection` (Task 54).

  The notification-access continuation reads the records this projection stores.
  What it may rely on is pinned here: the three `delivery.` event types inside
  the shared account-level store, the fixed recipient matrices, the minimized
  field contract with one safe in-product link, and the idempotent event key
  that makes at-least-once projection safe to read.

  The recipient half of the contract is Slice 08's repaired routing, verified
  from this consumer's side: routing follows active participation, so a current
  participant whose presentation was never established is still the person a
  blocked run reaches, while a departed one is dropped at delivery time.
  """
  use SddOrchestrator.DataCase, async: false

  import Swoosh.TestAssertions

  alias SddOrchestrator.Delivery.{DeliveryStore, RunNotifications}
  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.Notifications
  alias SddOrchestrator.Notifications.AccountNotification
  alias SddOrchestrator.Participation.{Boundary, Revocations}
  alias SddOrchestrator.ParticipationFixtures

  setup do
    context = DeliveryFixtures.delivery_project_fixture()

    # An active participant who never had a `ProjectMemberProfile`: the exact
    # person the Slice 08 repair exists for. Only the authorization record is
    # created, never the presentation.
    bare = ParticipationFixtures.invited_identity_fixture()
    ParticipationFixtures.participant_fixture(context.project, bare.hosted_identity)

    %{
      authority: context.workspace,
      project: context.project,
      owner: context.account,
      responsible: context.identity,
      bare: bare
    }
  end

  describe "the published projection contract" do
    test "the event vocabulary and recipient matrices are the consumer's fixed contract" do
      assert Enum.sort(RunNotifications.events()) == [:blocked, :failed, :ready_for_review]

      assert RunNotifications.event_type(:blocked) == "delivery.run_blocked"
      assert RunNotifications.event_type(:ready_for_review) == "delivery.run_ready_for_review"
      assert RunNotifications.event_type(:failed) == "delivery.run_failed"

      # The projection extends the shared store under its own namespace rather
      # than creating a second one, which is what lets one reader list both.
      assert "delivery" in AccountNotification.namespaces()

      assert RunNotifications.recipient_roles(:blocked) == [:responsible]
      assert RunNotifications.recipient_roles(:ready_for_review) == [:responsible, :owner]
      assert RunNotifications.recipient_roles(:failed) == [:initiator, :responsible, :owner]
    end

    test "a projected record carries the minimized fields, the key, and one safe link", ctx do
      feature = assigned_feature(ctx, ctx.responsible.account.id)
      run = blocked_run(ctx, feature)

      assert {:ok, [notification]} =
               RunNotifications.deliver(ctx.project.id, run, feature, :blocked)

      # The idempotent key the reader depends on: event type, subject, and the
      # run's post-transition state version, addressed to one account.
      assert notification.account_id == ctx.responsible.account.id
      assert notification.event_type == "delivery.run_blocked"
      assert notification.subject_ref == run.id
      assert notification.event_version == run.state_version

      # The minimized body: display context, what happened, when — and one
      # relative in-product link that is authorized again when it is opened.
      assert notification.title
      assert notification.body =~ feature.title
      assert notification.project_label == ctx.project.name
      assert notification.occurred_at
      refute notification.actor_label

      assert notification.link_path == "/projects/#{ctx.project.id}/features/#{feature.id}"
      refute notification.link_path =~ "://"

      content = notification.title <> notification.body <> notification.project_label
      refute content =~ run.branch
      refute content =~ run.id
      refute content =~ "@"

      # The stored record is the delivery; no external channel carries it.
      refute_email_sent()
    end

    test "replaying the same committed event stores exactly one record", ctx do
      feature = assigned_feature(ctx, ctx.responsible.account.id)
      run = blocked_run(ctx, feature)

      assert {:ok, [first]} = RunNotifications.deliver(ctx.project.id, run, feature, :blocked)
      assert {:ok, [again]} = RunNotifications.deliver(ctx.project.id, run, feature, :blocked)

      assert again.id == first.id
      assert length(Notifications.list(ctx.responsible.account.id)) == 1
    end
  end

  describe "recipient routing through the Slice 08 boundary" do
    test "an active participant with absent presentation is still routed [AC-42]", ctx do
      feature = assigned_feature(ctx, ctx.bare.account.id)
      run = blocked_run(ctx, feature)

      assert {:ok, [notification]} =
               RunNotifications.deliver(ctx.project.id, run, feature, :blocked)

      # Routing followed the authorization record, not the missing profile.
      assert notification.account_id == ctx.bare.account.id
      assert Notifications.list(ctx.owner.id) == []
    end

    test "the boundary reports the profile-less participant as absent, not missing", ctx do
      participants = Boundary.current_participants(ctx.project.id)

      assert bare = Enum.find(participants, &(&1.account_id == ctx.bare.account.id))
      assert bare.role == :participant
      assert bare.hosted_identity_id == ctx.bare.hosted_identity.id
      assert bare.presentation_state == :absent

      # The neutral label, never an email-derived one.
      assert bare.display_name == "Project participant"
      refute bare.display_name =~ "@"
    end

    test "every routed member is the minimum result and carries no address", ctx do
      for member <- Boundary.current_members(ctx.project.id) do
        assert Enum.sort(Map.keys(member)) ==
                 [:account_id, :display_name, :hosted_identity_id, :presentation_state, :role]

        refute member.display_name =~ "@"
      end
    end

    test "a departed recipient is dropped at delivery time", ctx do
      feature = assigned_feature(ctx, ctx.responsible.account.id)
      run = blocked_run(ctx, feature)

      {:ok, _removed} =
        Revocations.remove(ctx.project, ctx.owner.id, ctx.responsible.hosted_identity.id)

      assert {:ok, [notification]} =
               RunNotifications.deliver(ctx.project.id, run, feature, :blocked)

      # Responsibility fell back through the same resolution the screens use —
      # the creator here is the owner — and the departed person heard nothing
      # about the run. The removal notice itself is Slice 08's own record.
      assert notification.account_id == ctx.owner.id

      assert ctx.responsible.account.id
             |> Notifications.list()
             |> Enum.filter(&String.starts_with?(&1.event_type, "delivery."))
             |> Enum.empty?()
    end
  end

  defp assigned_feature(ctx, account_id) do
    DeliveryFixtures.feature_fixture(ctx.project, ctx.owner, %{
      assigned_account_id: account_id
    })
  end

  # The run as the projector receives it: after the authoritative transition,
  # carrying the state version that transition produced.
  defp blocked_run(ctx, feature) do
    run = DeliveryFixtures.run_fixture(ctx.project, feature)

    {:ok, %{run: running}} =
      DeliveryStore.commit(ctx.authority, ctx.project.id, [
        {:run, {:transition_run, run, "running", []}}
      ])

    {:ok, %{run: blocked}} =
      DeliveryStore.commit(ctx.authority, ctx.project.id, [
        {:run, {:transition_run, running, "blocked", []}}
      ])

    blocked
  end
end
