defmodule SddOrchestrator.Privacy.ParticipationAccountNotificationRetentionTest do
  @moduledoc """
  Task 2 proof for AC-02.

  A `participation.`-namespace `AccountNotification` row is deleted 90 days
  after its own `occurred_at`, whether it was read or left unread. Every
  approved `participation.*` event type is selected, a `delivery.`-namespace
  row and a row outside the approved notification vocabulary are never
  selected, the delete never changes current project authorization, and the
  shared runner's lock, restart, and reconciliation behavior all keep working
  alongside it.
  """

  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Accounts.Account
  alias SddOrchestrator.Notifications
  alias SddOrchestrator.Notifications.AccountNotification
  alias SddOrchestrator.Participation
  alias SddOrchestrator.Participation.ProjectParticipant
  alias SddOrchestrator.ParticipationFixtures
  alias SddOrchestrator.Privacy.{Retention, RetentionPruner}

  @day 24 * 60 * 60
  @window 90 * @day

  # The complete closed vocabulary of approved `participation.*` event types,
  # mirrored from `SddOrchestrator.Participation.ProjectNotifications`.
  @participation_event_types ~w(
    participation.invitation_expired
    participation.joined
    participation.participant_joined
    participation.invitation_declined
    participation.removed
    participation.left
  )

  describe "90-day participation notification cleanup" do
    test "deletes both a read and an unread notification at the 90-day boundary" do
      %{project: project, account: account} = owned_project()
      now = truncated_now()
      cutoff = DateTime.add(now, -@window, :second)

      unread = notification_fixture(account, project, "participation.joined", cutoff)
      to_read = notification_fixture(account, project, "participation.left", cutoff)
      {:ok, read} = Notifications.mark_read(account.id, to_read.id)

      assert %{expired_participation_notifications: 2} = Retention.prune_all(now)

      refute Repo.get(AccountNotification, unread.id)
      refute Repo.get(AccountNotification, read.id)
    end

    test "keeps a notification one day inside the boundary and removes an overdue one" do
      %{project: project, account: account} = owned_project()
      now = truncated_now()

      just_inside =
        notification_fixture(
          account,
          project,
          "participation.joined",
          DateTime.add(now, -@window + 1, :second)
        )

      overdue =
        notification_fixture(
          account,
          project,
          "participation.removed",
          DateTime.add(now, -@window - @day, :second)
        )

      assert %{expired_participation_notifications: 1} = Retention.prune_all(now)

      assert Repo.get(AccountNotification, just_inside.id)
      refute Repo.get(AccountNotification, overdue.id)
    end

    test "deletes every approved participation.* event type at the boundary" do
      %{project: project, account: account} = owned_project()
      now = truncated_now()
      cutoff = DateTime.add(now, -@window, :second)

      notifications =
        Enum.map(
          @participation_event_types,
          &notification_fixture(account, project, &1, cutoff)
        )

      assert %{expired_participation_notifications: 6} = Retention.prune_all(now)

      for notification <- notifications do
        refute Repo.get(AccountNotification, notification.id)
      end
    end

    test "never deletes a delivery-namespace notification for the same account" do
      %{project: project, account: account} = owned_project()
      now = truncated_now()
      cutoff = DateTime.add(now, -@window, :second)

      due = notification_fixture(account, project, "participation.joined", cutoff)

      # Recent enough that the pre-existing `delivery.` 90-day rule (also
      # registered in `prune_all/1`) would not select it either, isolating
      # this assertion to the participation selector's own `like` prefix.
      delivery =
        notification_fixture(
          account,
          project,
          "delivery.run_blocked",
          DateTime.add(now, -@day, :second)
        )

      assert %{expired_participation_notifications: 1, expired_delivery_notifications: 0} =
               Retention.prune_all(now)

      refute Repo.get(AccountNotification, due.id)
      assert Repo.get(AccountNotification, delivery.id)
    end

    test "never deletes a notification outside the approved namespace vocabulary" do
      %{project: project, account: account} = owned_project()
      now = truncated_now()
      cutoff = DateTime.add(now, -@window, :second)

      due = notification_fixture(account, project, "participation.left", cutoff)
      future = raw_namespace_notification_fixture(account, project, "governance.audit", cutoff)

      assert %{expired_participation_notifications: 1} = Retention.prune_all(now)

      refute Repo.get(AccountNotification, due.id)
      assert Repo.get(AccountNotification, future.id)
    end

    test "re-running the prune is idempotent" do
      %{project: project, account: account} = owned_project()
      now = truncated_now()
      cutoff = DateTime.add(now, -@window, :second)

      notification_fixture(account, project, "participation.joined", cutoff)

      assert %{expired_participation_notifications: 1} = Retention.prune_all(now)
      assert %{expired_participation_notifications: 0} = Retention.prune_all(now)
    end

    test "a notification not yet due in one pass is reconciled once it crosses the boundary" do
      %{project: project, account: account} = owned_project()
      now = truncated_now()

      due_soon =
        notification_fixture(
          account,
          project,
          "participation.joined",
          DateTime.add(now, -@window + 60, :second)
        )

      assert %{expired_participation_notifications: 0} = Retention.prune_all(now)
      assert Repo.get(AccountNotification, due_soon.id)

      later = DateTime.add(now, 120, :second)
      assert %{expired_participation_notifications: 1} = Retention.prune_all(later)
      refute Repo.get(AccountNotification, due_soon.id)
    end
  end

  describe "unchanged project authorization" do
    test "deleting a due notification leaves current participation and the account untouched" do
      %{project: project, account: account} = owned_project()
      active = active_participant(project)
      now = truncated_now()
      cutoff = DateTime.add(now, -@window, :second)

      notification =
        notification_fixture(
          account,
          project,
          "participation.participant_joined",
          cutoff,
          %{subject_ref: active.participant.id}
        )

      assert %{expired_participation_notifications: 1} = Retention.prune_all(now)
      refute Repo.get(AccountNotification, notification.id)

      kept_participant = Repo.get!(ProjectParticipant, active.participant.id)
      assert kept_participant.state == "active"
      assert kept_participant.hosted_identity_id == active.identity.hosted_identity.id
      assert Participation.active_participant(project.id, active.identity.hosted_identity.id)

      assert Repo.get!(Account, account.id).id == account.id
      assert Repo.get!(Account, active.identity.account.id).id == active.identity.account.id
    end
  end

  describe "locked retention workflow" do
    test "the advisory lock prevents concurrent notification cleanup" do
      %{project: project, account: account} = owned_project()
      now = truncated_now()

      due =
        notification_fixture(
          account,
          project,
          "participation.joined",
          DateTime.add(now, -@window, :second)
        )

      {:ok, connection} = Postgrex.start_link(postgrex_options())
      Process.unlink(connection)
      on_exit(fn -> if Process.alive?(connection), do: GenServer.stop(connection) end)

      assert %Postgrex.Result{rows: [[:void]]} =
               Postgrex.query!(
                 connection,
                 "SELECT pg_advisory_lock($1)",
                 [RetentionPruner.advisory_lock_key()]
               )

      assert :locked = RetentionPruner.prune_with_lock(now)
      assert Repo.get(AccountNotification, due.id)

      assert %Postgrex.Result{rows: [[true]]} =
               Postgrex.query!(
                 connection,
                 "SELECT pg_advisory_unlock($1)",
                 [RetentionPruner.advisory_lock_key()]
               )

      assert %{expired_participation_notifications: 1} = RetentionPruner.prune_with_lock(now)
      refute Repo.get(AccountNotification, due.id)
    end

    test "the supervisor restarts and a reconciliation pass still clears the notification" do
      %{project: project, account: account} = owned_project()
      now = truncated_now()

      due =
        notification_fixture(
          account,
          project,
          "participation.left",
          DateTime.add(now, -@window, :second)
        )

      first_pid = start_supervised!({RetentionPruner, interval: :timer.hours(1)})
      Process.exit(first_pid, :kill)

      assert_eventually(fn ->
        case Process.whereis(RetentionPruner) do
          pid when is_pid(pid) -> pid != first_pid
          _not_restarted -> false
        end
      end)

      assert %{expired_participation_notifications: 1} = RetentionPruner.prune_with_lock(now)
      refute Repo.get(AccountNotification, due.id)
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

  # Goes through the shared `Notifications.deliver/1` store, so every fixture
  # is subject to the same approved-namespace and required-field validation
  # any real projector uses. `event_type` can be any approved namespace
  # (`participation.` or `delivery.`), which is what the negative
  # cross-namespace tests above rely on.
  defp notification_fixture(account, project, event_type, occurred_at, overrides \\ %{}) do
    {:ok, notification} =
      Notifications.deliver(
        Map.merge(
          %{
            account_id: account.id,
            event_type: event_type,
            subject_ref: Ecto.UUID.generate(),
            event_version: 1,
            title: "A participation event",
            body: "Something happened in #{project.name}.",
            project_label: project.name,
            link_path: "/projects/#{project.id}/participation",
            occurred_at: DateTime.truncate(occurred_at, :second)
          },
          overrides
        )
      )

    notification
  end

  # Bypasses `AccountNotification.changeset/2`'s closed namespace vocabulary
  # (`participation`, `delivery`) entirely, to stand in for a hypothetical
  # future or unknown namespace that the current selector must never touch.
  defp raw_namespace_notification_fixture(account, project, event_type, occurred_at) do
    Repo.insert!(%AccountNotification{
      account_id: account.id,
      event_type: event_type,
      subject_ref: Ecto.UUID.generate(),
      event_version: 1,
      title: "A future event",
      body: "Some future-namespace body.",
      project_label: project.name,
      link_path: "/projects/#{project.id}",
      occurred_at: DateTime.truncate(occurred_at, :second)
    })
  end

  defp truncated_now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp assert_eventually(check, remaining \\ 300)

  defp assert_eventually(check, remaining) when remaining > 0 do
    if check.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(check, remaining - 1)
    end
  end

  defp assert_eventually(_check, 0), do: flunk("condition did not become true")

  defp postgrex_options do
    Repo.config()
    |> Keyword.take([:hostname, :port, :database, :username, :password])
    |> Keyword.put(:backoff_type, :stop)
  end
end
