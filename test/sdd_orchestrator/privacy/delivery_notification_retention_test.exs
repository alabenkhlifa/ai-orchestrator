defmodule SddOrchestrator.Privacy.DeliveryNotificationRetentionTest do
  @moduledoc """
  Task 5 proof for AC-05.

  A Slice 07 `delivery.`-namespace notification is deleted 90 days after its
  own `occurred_at`, whether read or unread, and this delete changes no
  feature, run, review, assignment, or participation state. Slice 08's
  `participation.`-namespace notifications on the same schema are never
  selected by this rule.
  """

  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Delivery.Feature
  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.Notifications
  alias SddOrchestrator.Notifications.AccountNotification
  alias SddOrchestrator.ParticipationFixtures
  alias SddOrchestrator.Privacy.{Retention, RetentionPruner}
  alias SddOrchestrator.Projects.Project

  @day 24 * 60 * 60
  @window 90 * @day

  describe "90-day Slice 07 notification cleanup" do
    test "deletes a delivery notification at the boundary whether unread or read" do
      %{project: project, account: account} = owned_project()
      feature = DeliveryFixtures.feature_fixture(project, account)
      now = truncated_now()
      cutoff = DateTime.add(now, -@window, :second)

      {:ok, unread} = notification_fixture(account, project, feature, cutoff)
      {:ok, will_be_read} = notification_fixture(account, project, feature, cutoff)
      {:ok, _read} = Notifications.mark_read(account.id, will_be_read.id)

      assert %{expired_delivery_notifications: 2} = Retention.prune_all(now)

      refute Repo.get(AccountNotification, unread.id)
      refute Repo.get(AccountNotification, will_be_read.id)
    end

    test "keeps a delivery notification just inside the boundary and removes one overdue" do
      %{project: project, account: account} = owned_project()
      feature = DeliveryFixtures.feature_fixture(project, account)
      now = truncated_now()

      just_inside =
        notification_fixture!(
          account,
          project,
          feature,
          DateTime.add(now, -@window + 1, :second)
        )

      overdue =
        notification_fixture!(
          account,
          project,
          feature,
          DateTime.add(now, -@window - @day, :second)
        )

      assert %{expired_delivery_notifications: 1} = Retention.prune_all(now)

      assert Repo.get(AccountNotification, just_inside.id)
      refute Repo.get(AccountNotification, overdue.id)
    end

    test "never selects a participation-namespace notification for the delivery category" do
      # specs/27 Task 2 added its own 90-day `participation.`-namespace rule to
      # the same shared `Retention.prune_all/1`, so an old-enough participation
      # notification is now legitimately removed too — by that rule, not this
      # one. What this test still proves is namespace selector isolation: the
      # delivery rule's `like "delivery.%"` filter never matches a
      # `participation.*` row, so the two categories never double-count or
      # cross-select the same row.
      %{project: project, account: account} = owned_project()
      feature = DeliveryFixtures.feature_fixture(project, account)
      now = truncated_now()
      long_past = DateTime.add(now, -@window - 90 * @day, :second)

      participation =
        notification_fixture!(account, project, feature, long_past, %{
          event_type: "participation.joined",
          subject_ref: Ecto.UUID.generate(),
          link_path: "/projects/#{project.id}/participation"
        })

      due = notification_fixture!(account, project, feature, DateTime.add(now, -@window, :second))

      assert %{expired_delivery_notifications: 1, expired_participation_notifications: 1} =
               Retention.prune_all(now)

      refute Repo.get(AccountNotification, due.id)
      refute Repo.get(AccountNotification, participation.id)
    end

    test "deleting an expired notification changes nothing else" do
      %{project: project, account: account} = owned_project()
      feature = DeliveryFixtures.feature_fixture(project, account)
      now = truncated_now()

      due = notification_fixture!(account, project, feature, DateTime.add(now, -@window, :second))

      assert %{expired_delivery_notifications: 1} = Retention.prune_all(now)
      refute Repo.get(AccountNotification, due.id)

      assert Repo.get!(Project, project.id) == project
      assert Repo.get!(Feature, feature.id) == feature
      assert Repo.get!(SddOrchestrator.Accounts.Account, account.id).id == account.id
    end

    test "re-running the prune a second time is a no-op" do
      %{project: project, account: account} = owned_project()
      feature = DeliveryFixtures.feature_fixture(project, account)
      now = truncated_now()

      notification_fixture!(account, project, feature, DateTime.add(now, -@window, :second))

      assert %{expired_delivery_notifications: 1} = Retention.prune_all(now)
      assert %{expired_delivery_notifications: 0} = Retention.prune_all(now)
    end
  end

  describe "supervised pruning" do
    test "the advisory lock prevents concurrent pruning" do
      %{project: project, account: account} = owned_project()
      feature = DeliveryFixtures.feature_fixture(project, account)
      now = truncated_now()

      due = notification_fixture!(account, project, feature, DateTime.add(now, -@window, :second))

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

      assert %{expired_delivery_notifications: 1} = RetentionPruner.prune_with_lock(now)
      refute Repo.get(AccountNotification, due.id)
    end

    test "the supervisor restarts the pruner and the reconciled prune succeeds" do
      %{project: project, account: account} = owned_project()
      feature = DeliveryFixtures.feature_fixture(project, account)
      now = truncated_now()

      due = notification_fixture!(account, project, feature, DateTime.add(now, -@window, :second))

      first_pid = start_supervised!({RetentionPruner, interval: :timer.hours(1)})
      Process.exit(first_pid, :kill)

      assert_eventually(fn ->
        case Process.whereis(RetentionPruner) do
          pid when is_pid(pid) -> pid != first_pid
          _not_restarted -> false
        end
      end)

      assert %{expired_delivery_notifications: 1} = RetentionPruner.prune_with_lock(now)
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

  defp notification_fixture(account, project, feature, occurred_at, overrides \\ %{}) do
    Notifications.deliver(notification_attrs(account, project, feature, occurred_at, overrides))
  end

  defp notification_fixture!(account, project, feature, occurred_at, overrides \\ %{}) do
    {:ok, notification} = notification_fixture(account, project, feature, occurred_at, overrides)
    notification
  end

  defp notification_attrs(account, project, feature, occurred_at, overrides) do
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
        occurred_at: DateTime.truncate(occurred_at, :second)
      },
      overrides
    )
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
