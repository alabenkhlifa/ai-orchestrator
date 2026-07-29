defmodule SddOrchestrator.NotificationsTest do
  use SddOrchestrator.DataCase, async: true

  alias Ecto.Multi
  alias SddOrchestrator.Notifications
  alias SddOrchestrator.Notifications.AccountNotification
  alias SddOrchestrator.ParticipationFixtures

  describe "deliver/1" do
    test "stores one durable unread record with only approved fields" do
      %{account: account, project: project} = ParticipationFixtures.hosted_project_fixture()

      assert {:ok, notification} = Notifications.deliver(attrs(account, project))

      assert notification.account_id == account.id
      assert notification.event_type == "participation.invitation_expired"
      assert notification.event_version == 1
      assert notification.read_at == nil
      assert AccountNotification.unread?(notification)
      assert notification.link_path == "/projects/#{project.id}/participation"
      assert Notifications.unread_count(account.id) == 1
    end

    test "is idempotent for a replayed event, subject, version, and recipient" do
      %{account: account, project: project} = ParticipationFixtures.hosted_project_fixture()

      assert {:ok, first} = Notifications.deliver(attrs(account, project))
      assert {:ok, replayed} = Notifications.deliver(attrs(account, project))

      assert replayed.id == first.id
      assert Repo.aggregate(AccountNotification, :count) == 1
      assert Notifications.unread_count(account.id) == 1
    end

    test "creates a separate record for a later subject state version" do
      %{account: account, project: project} = ParticipationFixtures.hosted_project_fixture()

      assert {:ok, first} = Notifications.deliver(attrs(account, project))

      assert {:ok, second} =
               Notifications.deliver(attrs(account, project, %{event_version: 2}))

      assert second.id != first.id
      assert Notifications.unread_count(account.id) == 2
    end

    test "keeps a replayed record read once its recipient marked it read" do
      %{account: account, project: project} = ParticipationFixtures.hosted_project_fixture()

      {:ok, notification} = Notifications.deliver(attrs(account, project))
      {:ok, read} = Notifications.mark_read(account.id, notification.id)

      assert {:ok, replayed} = Notifications.deliver(attrs(account, project))
      assert replayed.id == notification.id
      assert replayed.read_at == read.read_at
      assert Notifications.unread_count(account.id) == 0
    end

    test "rejects an unapproved event namespace, unsafe link, and oversized body" do
      %{account: account, project: project} = ParticipationFixtures.hosted_project_fixture()

      assert {:error, changeset} =
               Notifications.deliver(attrs(account, project, %{event_type: "marketing.campaign"}))

      assert "is not an approved notification event" in errors_on(changeset).event_type

      assert {:error, changeset} =
               Notifications.deliver(attrs(account, project, %{event_type: "invitation_expired"}))

      assert errors_on(changeset).event_type != []

      for unsafe <- [
            "https://example.com/projects",
            "//example.com/projects",
            "projects/1",
            "/projects/1 with space"
          ] do
        assert {:error, changeset} =
                 Notifications.deliver(attrs(account, project, %{link_path: unsafe}))

        assert "is not a safe in-product link" in errors_on(changeset).link_path
      end

      assert {:error, changeset} =
               Notifications.deliver(attrs(account, project, %{body: String.duplicate("x", 401)}))

      assert errors_on(changeset).body != []
    end

    test "accepts the reserved feature-delivery namespace so Slice 07 extends this store" do
      %{account: account, project: project} = ParticipationFixtures.hosted_project_fixture()

      assert "delivery" in AccountNotification.namespaces()

      assert {:ok, notification} =
               Notifications.deliver(
                 attrs(account, project, %{event_type: "delivery.run_ready_for_review"})
               )

      assert notification.event_type == "delivery.run_ready_for_review"
      assert Repo.aggregate(AccountNotification, :count) == 1
    end
  end

  describe "deliver_multi/3" do
    test "commits with authoritative state and stays idempotent on replay" do
      %{account: account, project: project} = ParticipationFixtures.hosted_project_fixture()

      run = fn ->
        Multi.new()
        |> Notifications.deliver_multi(:notification, attrs(account, project))
        |> Repo.transaction()
      end

      assert {:ok, %{notification: first}} = run.()
      assert {:ok, %{notification: replayed}} = run.()

      assert first.id
      assert replayed.id == first.id
      assert Repo.aggregate(AccountNotification, :count) == 1

      assert :ok = Notifications.publish_committed([first, replayed])
    end

    test "rolls the notification back with its transaction" do
      %{account: account, project: project} = ParticipationFixtures.hosted_project_fixture()

      assert {:error, :boom, :failed, _changes} =
               Multi.new()
               |> Notifications.deliver_multi(:notification, attrs(account, project))
               |> Multi.run(:boom, fn _repo, _changes -> {:error, :failed} end)
               |> Repo.transaction()

      assert Repo.aggregate(AccountNotification, :count) == 0
      assert Notifications.unread_count(account.id) == 0
    end
  end

  describe "account-boundary authorization" do
    test "lists, reads, and marks only the recipient's own notifications" do
      %{account: account, project: project} = ParticipationFixtures.hosted_project_fixture()
      %{account: other_account} = ParticipationFixtures.hosted_project_fixture()

      {:ok, notification} = Notifications.deliver(attrs(account, project))

      assert Enum.map(Notifications.list(account.id), & &1.id) == [notification.id]
      assert Notifications.list(other_account.id) == []
      assert Notifications.list(nil) == []
      assert Notifications.list("not-an-id") == []

      assert {:ok, _found} = Notifications.fetch(account.id, notification.id)
      assert {:error, :not_found} = Notifications.fetch(other_account.id, notification.id)
      assert {:error, :not_found} = Notifications.fetch(nil, notification.id)
      assert {:error, :not_found} = Notifications.fetch(account.id, Ecto.UUID.generate())
      assert {:error, :not_found} = Notifications.fetch(account.id, "not-an-id")

      assert {:error, :not_found} = Notifications.mark_read(other_account.id, notification.id)
      assert Notifications.unread_count(account.id) == 1
      assert Notifications.unread_count(other_account.id) == 0
      assert Notifications.unread_count(nil) == 0
    end

    test "orders newest first and can list only unread work" do
      %{account: account, project: project} = ParticipationFixtures.hosted_project_fixture()
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, older} =
        Notifications.deliver(
          attrs(account, project, %{
            subject_ref: "older",
            occurred_at: DateTime.add(now, -60, :second)
          })
        )

      {:ok, newer} =
        Notifications.deliver(attrs(account, project, %{subject_ref: "newer", occurred_at: now}))

      assert Enum.map(Notifications.list(account.id), & &1.id) == [newer.id, older.id]

      {:ok, _read} = Notifications.mark_read(account.id, newer.id)

      assert Enum.map(Notifications.list(account.id, unread_only: true), & &1.id) == [older.id]
      assert Notifications.unread_count(account.id) == 1
    end
  end

  describe "mark_read/3" do
    test "is idempotent and preserves the first read time" do
      %{account: account, project: project} = ParticipationFixtures.hosted_project_fixture()
      {:ok, notification} = Notifications.deliver(attrs(account, project))
      first_read = DateTime.utc_now() |> DateTime.add(-120, :second) |> DateTime.truncate(:second)

      assert {:ok, read} = Notifications.mark_read(account.id, notification.id, first_read)
      assert read.read_at == first_read
      refute AccountNotification.unread?(read)

      assert {:ok, again} = Notifications.mark_read(account.id, notification.id)
      assert again.read_at == first_read
      assert Notifications.unread_count(account.id) == 0
    end
  end

  describe "delivery without PubSub" do
    test "durable unread state survives with no subscriber and is found later" do
      %{account: account, project: project} = ParticipationFixtures.hosted_project_fixture()

      # No process subscribes: the stored record is the delivery guarantee.
      {:ok, notification} = Notifications.deliver(attrs(account, project))

      refute_receive {:account_notification, _id}, 50

      reloaded = Repo.get!(AccountNotification, notification.id)
      assert AccountNotification.unread?(reloaded)
      assert Enum.map(Notifications.list(account.id), & &1.id) == [notification.id]
    end

    test "publishes a presentation hint to a subscribed recipient" do
      %{account: account, project: project} = ParticipationFixtures.hosted_project_fixture()

      :ok = Notifications.subscribe(account.id)
      {:ok, notification} = Notifications.deliver(attrs(account, project))

      assert_receive {:account_notification, id}
      assert id == notification.id
      assert Notifications.topic(account.id) =~ account.id
    end
  end

  describe "content minimization" do
    test "the stored schema exposes no free-form payload column" do
      columns = AccountNotification.__schema__(:fields) |> Enum.sort()

      assert columns == [
               :account_id,
               :actor_label,
               :body,
               :event_type,
               :event_version,
               :id,
               :inserted_at,
               :link_path,
               :occurred_at,
               :project_label,
               :read_at,
               :subject_ref,
               :title,
               :updated_at
             ]

      refute Enum.any?(columns, &(&1 in [:payload, :metadata, :context, :data]))
    end
  end

  defp attrs(account, project, overrides \\ %{}) do
    Map.merge(
      %{
        account_id: account.id,
        event_type: "participation.invitation_expired",
        subject_ref: project.id,
        event_version: 1,
        title: "An invitation expired",
        body: "One pending invitation expired without being accepted.",
        project_label: project.name,
        link_path: "/projects/#{project.id}/participation"
      },
      overrides
    )
  end
end
