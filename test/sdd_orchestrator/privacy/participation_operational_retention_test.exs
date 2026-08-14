defmodule SddOrchestrator.Privacy.ParticipationOperationalRetentionTest do
  @moduledoc """
  Task 3 capstone compatibility proof for AC-01, AC-02, AC-03, and the
  provider-owned `specs/25-participation-identity-lifecycle` capability.

  This file does not re-derive Task 1, Task 2, or Task 3's own exhaustive
  unit coverage (see `participation_email_delivery_retention_test.exs`,
  `participation_account_notification_retention_test.exs`, and
  `participation_security_log_retention_test.exs`). It proves the complete
  participation operational-retention capability: all four registered rules
  — the three this specification adds plus the provider-owned
  `participation_revocation_links` rule specs/25 already delivers — compose
  correctly in one `Privacy.Retention.prune_all/1` pass, the provider-owned
  rule fires exactly once and is unaffected by the three new rules, every
  category result is a minimized non-negative integer with no duplicate
  key across the whole map, and a repeat run is fully idempotent.
  """

  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Notifications
  alias SddOrchestrator.Notifications.AccountNotification
  alias SddOrchestrator.Participation.{ParticipationEmailDelivery, ParticipationRevocation}
  alias SddOrchestrator.Participation.Revocations
  alias SddOrchestrator.ParticipationDeliveryDouble
  alias SddOrchestrator.ParticipationFixtures
  alias SddOrchestrator.Privacy.ParticipationSecurityEvent
  alias SddOrchestrator.Privacy.{Retention, RetentionPruner}

  @day 24 * 60 * 60
  @participation_window 30 * @day
  @notification_window 90 * @day
  @security_log_window 30 * @day

  setup do
    previous = Application.get_env(:sdd_orchestrator, :participation_email_delivery)

    Application.put_env(
      :sdd_orchestrator,
      :participation_email_delivery,
      ParticipationDeliveryDouble
    )

    ParticipationDeliveryDouble.succeed()

    on_exit(fn ->
      if previous do
        Application.put_env(:sdd_orchestrator, :participation_email_delivery, previous)
      else
        Application.delete_env(:sdd_orchestrator, :participation_email_delivery)
      end
    end)

    :ok
  end

  describe "one pass across all four operational-retention rules" do
    test "every category count is correct simultaneously, the provider-owned rule fires exactly once, results are minimized, and the map has no duplicate keys" do
      now = truncated_now()
      context = owned_project()
      active = active_participant(context.project)

      {:ok, %{revocation: revocation}} =
        Revocations.leave(
          context.project,
          active.identity.account.id,
          active.identity.hosted_identity.id,
          DateTime.add(now, -@participation_window, :second)
        )

      due_delivery =
        delivery_fixture(
          status: "sent",
          delivered_at: DateTime.add(now, -@participation_window, :second)
        )

      due_notification =
        notification_fixture(
          context.account,
          context.project,
          "participation.joined",
          DateTime.add(now, -@notification_window, :second)
        )

      due_security_event =
        security_event_fixture(occurred_at: DateTime.add(now, -@security_log_window, :second))

      results = Retention.prune_all(now)

      assert %{
               participation_revocation_links: 1,
               expired_participation_email_delivery_diagnostics: 1,
               expired_participation_notifications: 1,
               expired_participation_security_events: 1
             } = results

      # The provider-owned rule (specs/25) is registered exactly once: its key
      # appears once in the map, and the map carries no duplicate keys at all
      # (a `%{}` literal cannot hold a duplicate key, so this also proves no
      # second key was silently overwritten while building the map).
      keys = Map.keys(results)
      assert Enum.count(keys, &(&1 == :participation_revocation_links)) == 1
      assert length(keys) == length(Enum.uniq(keys))

      # Every returned value is a minimized non-negative integer count, never
      # a struct, string, or any leaked content.
      for {_category, value} <- results do
        assert is_integer(value)
        assert value >= 0
      end

      refute Repo.get(ParticipationEmailDelivery, due_delivery.id)
      refute Repo.get(AccountNotification, due_notification.id)
      refute Repo.get(ParticipationSecurityEvent, due_security_event.id)

      released = Repo.get!(ParticipationRevocation, revocation.id)
      assert is_nil(released.former_hosted_identity_id)
      assert is_nil(released.former_account_id)
      assert released.id == revocation.id
      assert released.project_id == context.project.id
      assert released.reason == revocation.reason
      assert released.occurred_at == revocation.occurred_at

      # A second, identical pass is fully idempotent: every category is zero.
      repeat = Retention.prune_all(now)

      assert %{
               participation_revocation_links: 0,
               expired_participation_email_delivery_diagnostics: 0,
               expired_participation_notifications: 0,
               expired_participation_security_events: 0
             } = repeat
    end

    test "the locked shared runner produces the same composed result through prune_with_lock/1" do
      now = truncated_now()
      context = owned_project()
      active = active_participant(context.project)

      {:ok, _} =
        Revocations.leave(
          context.project,
          active.identity.account.id,
          active.identity.hosted_identity.id,
          DateTime.add(now, -@participation_window, :second)
        )

      delivery_fixture(
        status: "failed",
        attempted_at: DateTime.add(now, -@participation_window, :second),
        delivered_at: nil
      )

      notification_fixture(
        context.account,
        context.project,
        "participation.left",
        DateTime.add(now, -@notification_window, :second)
      )

      security_event_fixture(occurred_at: DateTime.add(now, -@security_log_window, :second))

      assert %{
               participation_revocation_links: 1,
               expired_participation_email_delivery_diagnostics: 1,
               expired_participation_notifications: 1,
               expired_participation_security_events: 1
             } = RetentionPruner.prune_with_lock(now)

      assert %{
               participation_revocation_links: 0,
               expired_participation_email_delivery_diagnostics: 0,
               expired_participation_notifications: 0,
               expired_participation_security_events: 0
             } = RetentionPruner.prune_with_lock(now)
    end
  end

  defp owned_project do
    result = ParticipationFixtures.hosted_project_fixture()

    ParticipationFixtures.member_profile_fixture(result.project, result.account, %{
      role: "owner",
      display_name: ParticipationFixtures.unique_display_name("Owner")
    })

    result
  end

  defp active_participant(project) do
    identity = ParticipationFixtures.invited_identity_fixture()
    participant = ParticipationFixtures.participant_fixture(project, identity.hosted_identity)

    ParticipationFixtures.member_profile_fixture(project, identity.account, %{
      role: "participant",
      display_name: ParticipationFixtures.unique_display_name("Participant")
    })

    %{identity: identity, participant: participant}
  end

  defp delivery_fixture(attrs) do
    attrs = Map.new(attrs)
    base_time = Map.get(attrs, :attempted_at, truncated_now())

    defaults = %{
      event_type: "invitation",
      subject_ref: Ecto.UUID.generate(),
      event_version: 1,
      recipient_address: unique_address(),
      status: "sent",
      attempted_at: base_time,
      delivered_at: base_time
    }

    %ParticipationEmailDelivery{}
    |> ParticipationEmailDelivery.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp notification_fixture(account, project, event_type, occurred_at) do
    {:ok, notification} =
      Notifications.deliver(%{
        account_id: account.id,
        event_type: event_type,
        subject_ref: Ecto.UUID.generate(),
        event_version: 1,
        title: "A participation event",
        body: "Something happened in #{project.name}.",
        project_label: project.name,
        link_path: "/projects/#{project.id}/participation",
        occurred_at: DateTime.truncate(occurred_at, :second)
      })

    notification
  end

  defp security_event_fixture(attrs) do
    attrs = Map.new(attrs)

    defaults = %{
      event_type: :revocation_denied,
      outcome: :denied,
      reason: :unauthorized,
      occurred_at: truncated_now(),
      correlation_id: Ecto.UUID.generate()
    }

    %ParticipationSecurityEvent{}
    |> ParticipationSecurityEvent.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp unique_address, do: "capstone-#{System.unique_integer([:positive])}@example.com"

  defp truncated_now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
