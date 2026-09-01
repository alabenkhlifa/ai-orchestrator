defmodule SddOrchestrator.Delivery.RunNotificationsTest do
  @moduledoc """
  Proof for run-event notifications (Task 36).

  One promise is pinned above every other: a run event reaches the smallest set
  of people who currently have to act on it, and nobody else. The three matrices
  are asserted as sets rather than by spot check — a block reaches the
  responsible participant, a review reaches that person and the owner, a
  terminal failure reaches those two and the run's initiator — with a departed
  recipient dropped and a person holding several roles told exactly once.

  The second promise is that delivery is the stored record. The projector
  consumes a committed lifecycle event at least once, so the same event is
  projected twice on purpose here and has to store one row; a later event on the
  same run has to store a second one, because the run's post-transition state
  version is what tells the two apart. Nothing about that depends on PubSub,
  which is proven by delivering with nobody subscribed at all.

  The third is minimization. A notification carries the project and feature
  display context, what happened, and one link. The branch, the commit, the
  question text, the evidence, and every address stay behind that link, and no
  external channel carries any of it.
  """
  use SddOrchestrator.DataCase, async: false

  import Swoosh.TestAssertions

  alias SddOrchestrator.Accounts.DeviceWorkspace

  alias SddOrchestrator.Delivery.{
    AgentRun,
    Blocking,
    DeliveryStore,
    EventIngestion,
    Feature,
    Reconciliation,
    Retry,
    Review,
    ReviewHandoff,
    RunAttempt,
    RunNotifications,
    WorkerProtocol
  }

  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.DeviceStore.Local
  alias SddOrchestrator.Notifications
  alias SddOrchestrator.Notifications.AccountNotification
  alias SddOrchestrator.Participation
  alias SddOrchestrator.Participation.Revocations
  alias SddOrchestrator.ParticipationFixtures
  alias SddOrchestrator.Repo

  @blocked "delivery.run_blocked"
  @review "delivery.run_ready_for_review"
  @failed "delivery.run_failed"

  @contract ["mix test"]
  @lost "worker_unavailable"

  # A fixed clock, because the reconciliation lease boundary must not depend on
  # how long a test takes to run.
  @now ~U[2026-07-29 09:00:00Z]
  @lease_seconds 60
  @worker "wrk_alpha"

  setup do
    root = Path.join(System.tmp_dir!(), "run-notifications-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    put_env(:worker_workspace_root, root)

    hosted = DeliveryFixtures.delivery_project_fixture()

    # The three roles are deliberately three different people. A fixture that
    # covered two of them with one account would prove neither matrix.
    initiator = current_participant(hosted.project, "Initiator")

    feature =
      hosted.project
      |> DeliveryFixtures.feature_fixture(hosted.account, %{
        assigned_account_id: hosted.identity.account.id
      })
      |> in_development()

    run =
      DeliveryFixtures.run_fixture(hosted.project, feature, %{
        initiator_account_id: initiator.account.id
      })

    pending =
      DeliveryFixtures.attempt_fixture(run, %{
        fence_token: 3,
        required_checks: DeliveryFixtures.required_check_contract(@contract)
      })

    {:ok, attempt} =
      pending
      |> RunAttempt.transition_changeset("dispatched", pending.state_version)
      |> Repo.update()

    %{
      authority: hosted.workspace,
      hosted: hosted,
      project: hosted.project,
      owner: hosted.account,
      owner_actor: hosted.owner_actor,
      responsible: hosted.identity,
      initiator: initiator,
      feature: feature,
      run: run,
      attempt: attempt
    }
  end

  describe "who one run event reaches" do
    test "a blocked run reaches the current responsible participant alone [AC-27]", ctx do
      run = blocked(ctx)

      assert {:ok, [notification]} =
               RunNotifications.deliver(ctx.project.id, run, ctx.feature, :blocked)

      assert notification.account_id == ctx.responsible.account.id
      assert notification.event_type == @blocked
      assert notification.subject_ref == run.id
      assert notification.event_version == run.state_version

      assert Notifications.list(ctx.owner.id) == []
      assert Notifications.list(ctx.initiator.account.id) == []
      assert Repo.aggregate(AccountNotification, :count) == 1
    end

    test "review-ready reaches the responsible participant and the project owner [AC-27]", ctx do
      run = current_run(ctx)

      assert {:ok, notifications} =
               RunNotifications.deliver(ctx.project.id, run, ctx.feature, :ready_for_review)

      assert accounts(notifications) == Enum.sort([ctx.responsible.account.id, ctx.owner.id])
      assert Enum.all?(notifications, &(&1.event_type == @review))

      assert Notifications.list(ctx.initiator.account.id) == []
      assert Repo.aggregate(AccountNotification, :count) == 2
    end

    test "a terminal failure reaches the initiator, the responsible, and the owner [AC-27]",
         ctx do
      run = terminally_failed(ctx)

      assert {:ok, notifications} =
               RunNotifications.deliver(ctx.project.id, run, ctx.feature, :failed)

      assert accounts(notifications) ==
               Enum.sort([ctx.initiator.account.id, ctx.responsible.account.id, ctx.owner.id])

      assert Enum.all?(notifications, &(&1.event_type == @failed))
      assert Repo.aggregate(AccountNotification, :count) == 3
    end

    test "one person holding every role is notified once [AC-27]", ctx do
      # The owner created the feature, took it, and started the run.
      solo = developed_feature(ctx, %{assigned_account_id: ctx.owner.id})
      run = failed_run(ctx, solo, ctx.owner.id)

      assert {:ok, [notification]} = RunNotifications.deliver(ctx.project.id, run, solo, :failed)

      assert notification.account_id == ctx.owner.id
      assert Repo.aggregate(AccountNotification, :count) == 1

      # Three roles were genuinely asked for, and they collapsed to one person.
      assert RunNotifications.recipient_roles(:failed) == [:initiator, :responsible, :owner]
    end

    test "a recipient who left the project receives nothing [AC-27]", ctx do
      {:ok, _removed} =
        Revocations.remove(ctx.project, ctx.owner.id, ctx.initiator.hosted_identity.id)

      run = terminally_failed(ctx)

      assert {:ok, notifications} =
               RunNotifications.deliver(ctx.project.id, run, ctx.feature, :failed)

      assert accounts(notifications) == Enum.sort([ctx.responsible.account.id, ctx.owner.id])
      assert notifications(ctx.initiator.account.id, @failed) == []
    end

    test "an active responsible participant without a profile remains the recipient [AC-42]",
         ctx do
      delete_profile(ctx.project.id, ctx.responsible.account.id)

      run = blocked(ctx)

      assert {:ok, [notification]} =
               RunNotifications.deliver(ctx.project.id, run, ctx.feature, :blocked)

      assert notification.account_id == ctx.responsible.account.id
      assert notifications(ctx.owner.id, @blocked) == []
    end

    test "an immutable owner without a profile remains a review recipient [AC-42]", ctx do
      delete_profile(ctx.project.id, ctx.owner.id)

      assert {:ok, notifications} =
               RunNotifications.deliver(
                 ctx.project.id,
                 current_run(ctx),
                 ctx.feature,
                 :ready_for_review
               )

      assert accounts(notifications) == Enum.sort([ctx.responsible.account.id, ctx.owner.id])
    end

    test "a departed assignee moves responsibility rather than losing it [AC-27]", ctx do
      {:ok, _removed} =
        Revocations.remove(ctx.project, ctx.owner.id, ctx.responsible.hosted_identity.id)

      run = blocked(ctx)

      assert {:ok, [notification]} =
               RunNotifications.deliver(ctx.project.id, run, ctx.feature, :blocked)

      # The creator is the owner here, which is the fallback `Assignment` owns.
      assert notification.account_id == ctx.owner.id
      assert notifications(ctx.responsible.account.id, @blocked) == []
    end

    test "a run nobody started still notifies the roles that resolve [AC-27]", ctx do
      anonymous = developed_feature(ctx, %{assigned_account_id: ctx.responsible.account.id})
      run = failed_run(ctx, anonymous, nil)

      assert {:ok, notifications} =
               RunNotifications.deliver(ctx.project.id, run, anonymous, :failed)

      assert accounts(notifications) == Enum.sort([ctx.responsible.account.id, ctx.owner.id])
    end

    test "a project with no participation to read stores nothing and fails nothing", ctx do
      run = terminally_failed(ctx)

      assert {:ok, []} =
               RunNotifications.deliver(Ecto.UUID.generate(), run, ctx.feature, :failed)

      assert Repo.aggregate(AccountNotification, :count) == 0
    end
  end

  describe "replay and restart" do
    test "projecting the same event twice stores one record [AC-27]", ctx do
      run = blocked(ctx)

      assert {:ok, [first]} = RunNotifications.deliver(ctx.project.id, run, ctx.feature, :blocked)
      assert {:ok, [again]} = RunNotifications.deliver(ctx.project.id, run, ctx.feature, :blocked)

      assert again.id == first.id
      assert Repo.aggregate(AccountNotification, :count) == 1
      assert length(Notifications.list(ctx.responsible.account.id)) == 1
    end

    test "a later event on the same run is a new notification, not a duplicate [AC-27]", ctx do
      {:ok, [first]} =
        RunNotifications.deliver(ctx.project.id, blocked(ctx), ctx.feature, :blocked)

      resumed = transition(ctx, "running")
      {:ok, %{run: reblocked}} = commit(ctx, [{:run, {:transition_run, resumed, "blocked", []}}])

      {:ok, [second]} =
        RunNotifications.deliver(ctx.project.id, reblocked, ctx.feature, :blocked)

      refute second.id == first.id
      assert second.event_version > first.event_version
      assert length(Notifications.list(ctx.responsible.account.id)) == 2
    end

    test "the unread record survives with nobody subscribed [AC-27]", ctx do
      run = blocked(ctx)

      assert {:ok, [notification]} =
               RunNotifications.deliver(ctx.project.id, run, ctx.feature, :blocked)

      # Nothing listened, and the delivery still happened: the row is the
      # promise, so a disconnected or restarted reader finds the same work.
      refute_received {:account_notification, _id}
      assert AccountNotification.unread?(Repo.get!(AccountNotification, notification.id))
      assert Notifications.unread_count(ctx.responsible.account.id) == 1
      assert [^notification] = Notifications.list(ctx.responsible.account.id, unread_only: true)
    end

    test "a connected reader is hinted only after the record is committed [AC-27]", ctx do
      :ok = Notifications.subscribe(ctx.responsible.account.id)

      {:ok, [notification]} =
        RunNotifications.deliver(ctx.project.id, blocked(ctx), ctx.feature, :blocked)

      assert_receive {:account_notification, id}
      assert id == notification.id
      assert Repo.get(AccountNotification, id)
    end
  end

  describe "what a notification is allowed to say" do
    test "carries the display context and the action, and nothing behind the link [AC-27]",
         ctx do
      run = blocked(ctx)

      {:ok, [notification]} = RunNotifications.deliver(ctx.project.id, run, ctx.feature, :blocked)

      assert notification.body =~ ctx.feature.title
      assert notification.project_label == ctx.project.name
      assert notification.occurred_at

      # A run event has no human author, so no name is invented for one.
      refute notification.actor_label

      content = content(notification)
      refute content =~ run.branch
      refute content =~ run.id
      refute content =~ "@"
      refute content =~ ctx.responsible.external_identity.display_identifier
      refute content =~ ctx.initiator.external_identity.display_identifier
      refute content =~ "token"
      refute content =~ "secret"
    end

    test "carries one safe in-product link to the feature itself [AC-27]", ctx do
      {:ok, notifications} =
        RunNotifications.deliver(ctx.project.id, current_run(ctx), ctx.feature, :ready_for_review)

      for notification <- notifications do
        assert notification.link_path ==
                 "/projects/#{ctx.project.id}/features/#{ctx.feature.id}"

        refute String.starts_with?(notification.link_path, "//")
        refute notification.link_path =~ "?"
        refute notification.link_path =~ "://"
      end
    end

    test "shortens a long feature title on a grapheme boundary rather than refusing it", ctx do
      # Two hundred bytes of multi-byte graphemes: the longest title a feature
      # may hold, and one a byte-wise cut would corrupt.
      long = developed_feature(ctx, %{title: String.duplicate("é", 100)})
      run = failed_run(ctx, long, ctx.initiator.account.id)

      assert {:ok, notifications} = RunNotifications.deliver(ctx.project.id, run, long, :failed)
      assert notifications != []

      for notification <- notifications do
        assert String.valid?(notification.body)
        assert byte_size(notification.body) <= 400
        assert notification.body =~ String.duplicate("é", 60)
        refute notification.body =~ long.title
      end
    end

    test "no external channel carries a run event [AC-27]", ctx do
      {:ok, _blocked} =
        RunNotifications.deliver(ctx.project.id, blocked(ctx), ctx.feature, :blocked)

      {:ok, _review} =
        RunNotifications.deliver(ctx.project.id, current_run(ctx), ctx.feature, :ready_for_review)

      {:ok, _failed} =
        RunNotifications.deliver(ctx.project.id, terminally_failed(ctx), ctx.feature, :failed)

      assert Repo.aggregate(AccountNotification, :count) > 0
      refute_email_sent()
    end
  end

  describe "delivery state held on a device" do
    setup ctx do
      path =
        Path.join(
          System.tmp_dir!(),
          "run-notifications-#{System.unique_integer([:positive])}.dets"
        )

      start_supervised!({Local, path: path})
      on_exit(fn -> File.rm_rf(path) end)

      {:ok, workspace} = Devices.establish_workspace()

      Map.put(ctx, :device, %DeviceWorkspace{id: workspace.id})
    end

    test "a device-authoritative run still notifies hosted accounts [AC-27]", ctx do
      {:ok, _written} =
        Devices.commit_delivery(ctx.project.id, [
          {:put, :feature, ctx.feature.id, Feature.to_value(ctx.feature), nil}
        ])

      unique = System.unique_integer([:positive])
      digest = DeliveryFixtures.digest("rev-#{unique}")

      {:ok, %{run: inserted}} =
        DeliveryStore.commit(ctx.device, ctx.project.id, [
          {:run,
           {:insert_run,
            %{
              project_id: ctx.project.id,
              feature_id: ctx.feature.id,
              initiator_account_id: ctx.initiator.account.id,
              starting_revision_id: "rev-#{unique}",
              starting_revision_digest: digest,
              approved_slice: "slice-07",
              branch: "sdd/device-#{unique}"
            }}}
        ])

      {:ok, %{run: running}} =
        DeliveryStore.commit(ctx.device, ctx.project.id, [
          {:run, {:transition_run, inserted, "running", []}}
        ])

      {:ok, %{run: run}} =
        DeliveryStore.commit(ctx.device, ctx.project.id, [
          {:run, {:transition_run, running, "blocked", []}}
        ])

      assert {:ok, [notification]} =
               RunNotifications.deliver(ctx.project.id, run, ctx.feature, :blocked)

      assert notification.account_id == ctx.responsible.account.id
      assert notification.subject_ref == run.id
      assert notification.event_version == run.state_version

      # The run never reached the hosted database at all. What resolved the
      # recipient was participation, which is a hosted record whichever
      # authority holds the delivery state, so this is not a device-project copy.
      refute Repo.get(AgentRun, run.id)
    end
  end

  describe "the lifecycle events themselves" do
    test "a worker's blocking question notifies the responsible participant [AC-27]", ctx do
      ctx = running(ctx)
      question = "Should a departed member's comments stay visible?"

      {:ok, _results} =
        Blocking.ingest(
          ctx.authority,
          ctx.project.id,
          blocked_event(ctx, sequence: 2, question: question)
        )

      assert [notification] = notifications(ctx.responsible.account.id, @blocked)
      assert notification.link_path == "/projects/#{ctx.project.id}/features/#{ctx.feature.id}"

      # The question itself stays behind the link.
      refute content(notification) =~ question
      assert notifications(ctx.owner.id, @blocked) == []
    end

    test "a terminal execution failure notifies all three roles [AC-27]", ctx do
      ctx = running(ctx)

      {:ok, _results} =
        Retry.handle_failure(
          ctx.authority,
          ctx.project.id,
          failure_event(ctx, sequence: 2, reason: "invalid_authorization")
        )

      for account_id <- [ctx.initiator.account.id, ctx.responsible.account.id, ctx.owner.id] do
        assert [_notification] = notifications(account_id, @failed)
      end

      assert Repo.aggregate(AccountNotification, :count) == 3
    end

    test "a scheduled automatic retry notifies nobody [AC-27]", ctx do
      ctx = running(ctx)

      {:ok, results} =
        Retry.handle_failure(
          ctx.authority,
          ctx.project.id,
          failure_event(ctx, sequence: 2, reason: "transport_lost")
        )

      # Recovery is still in progress, so nobody is asked to act on it.
      assert results.command
      assert Repo.aggregate(AccountNotification, :count) == 0
    end

    test "the handoff to review notifies the responsible participant and the owner [AC-27]",
         ctx do
      verify(ctx)

      {:ok, %{applied?: true}} =
        ReviewHandoff.deliver(ctx.authority, ctx.project.id, ctx.run)

      assert [notification] = notifications(ctx.responsible.account.id, @review)
      assert [_owner_event] = notifications(ctx.owner.id, @review)
      assert notifications(ctx.initiator.account.id, @review) == []

      # The commit that was proved stays behind the link.
      refute content(notification) =~ "a1b2c3d4e5f6a7b8c9d0"

      # Handing the same completion over again is not a second event.
      {:ok, %{applied?: false}} = ReviewHandoff.deliver(ctx.authority, ctx.project.id, ctx.run)
      assert Repo.aggregate(AccountNotification, :count) == 2
    end

    test "feedback that contradicts the agreement blocks the run and notifies [AC-27]", ctx do
      ctx = reviewable(ctx)

      {:ok, _decision} =
        Review.reject(ctx.authority, ctx.owner_actor, subject(ctx), "The agreement is wrong",
          contradicts_agreement?: true
        )

      assert [notification] = notifications(ctx.responsible.account.id, @blocked)
      assert notification.subject_ref == ctx.run.id
      refute content(notification) =~ "The agreement is wrong"
      assert notifications(ctx.owner.id, @blocked) == []
    end

    test "an ordinary rejection continues the run and blocks nobody [AC-27]", ctx do
      ctx = reviewable(ctx)

      {:ok, _decision} =
        Review.reject(ctx.authority, ctx.owner_actor, subject(ctx), "The empty state spins")

      assert notifications(ctx.responsible.account.id, @blocked) == []
      assert notifications(ctx.owner.id, @blocked) == []
    end

    test "a lost execution nobody can recover notifies all three roles [AC-27]", ctx do
      ctx = ctx |> running() |> exhausted()

      assert {:ok, [decision]} =
               Reconciliation.reconcile(ctx.authority, ctx.project.id, snapshot(ctx),
                 now: DateTime.add(@now, @lease_seconds + 1, :second)
               )

      assert decision.outcome == :terminal

      for account_id <- [ctx.initiator.account.id, ctx.responsible.account.id, ctx.owner.id] do
        assert [notification] = notifications(account_id, @failed)
        refute content(notification) =~ @lost
      end
    end
  end

  defp content(notification) do
    notification.title <>
      notification.body <> (notification.project_label || "") <> (notification.actor_label || "")
  end

  defp accounts(notifications), do: notifications |> Enum.map(& &1.account_id) |> Enum.sort()

  defp notifications(account_id, event_type),
    do: account_id |> Notifications.list() |> Enum.filter(&(&1.event_type == event_type))

  defp delete_profile(project_id, account_id) do
    project_id
    |> Participation.member_profile(account_id)
    |> Repo.delete!()
  end

  defp commit(ctx, steps), do: DeliveryStore.commit(ctx.authority, ctx.project.id, steps)

  defp current_run(ctx) do
    {:ok, run} = DeliveryStore.fetch_run(ctx.authority, ctx.project.id, ctx.run.id)
    run
  end

  defp transition(ctx, state, opts \\ []) do
    {:ok, %{run: run}} = commit(ctx, [{:run, {:transition_run, current_run(ctx), state, opts}}])
    run
  end

  # The run as the projector actually receives it: after the authoritative
  # transition, carrying the state version that transition produced.
  defp blocked(ctx) do
    transition(ctx, "running")
    transition(ctx, "blocked")
  end

  defp terminally_failed(ctx) do
    transition(ctx, "running")
    transition(ctx, "failed", failure_reason: @lost)
  end

  # A second feature of the same project with its own failed run, for the cases
  # that need a different creator, assignee, title, or initiator.
  defp developed_feature(ctx, attrs) do
    attrs = Map.new(attrs)

    ctx.project
    |> DeliveryFixtures.feature_fixture(ctx.owner, attrs)
    |> in_development()
  end

  defp failed_run(ctx, feature, initiator_account_id) do
    run =
      DeliveryFixtures.run_fixture(ctx.project, feature, %{
        initiator_account_id: initiator_account_id
      })

    {:ok, %{run: running}} = commit(ctx, [{:run, {:transition_run, run, "running", []}}])

    {:ok, %{run: failed}} =
      commit(ctx, [{:run, {:transition_run, running, "failed", [failure_reason: @lost]}}])

    failed
  end

  # A run reports that it is working before it reports that it is stuck or that
  # it failed, so the event paths are exercised from the state they really see.
  defp running(ctx) do
    {:ok, _progress} =
      EventIngestion.ingest(ctx.authority, ctx.project.id, progress_event(ctx))

    {:ok, attempt} = DeliveryStore.latest_attempt(ctx.authority, ctx.project.id, ctx.run.id)

    %{ctx | run: current_run(ctx), attempt: attempt}
  end

  # Verified proof, then the handoff that actually puts the feature in front of a
  # reviewer. Reaching `Ready for review` any other way would prove the fixture.
  defp verify(ctx) do
    DeliveryFixtures.verified_completion_fixture(
      ctx.authority,
      ctx.project,
      ctx.run,
      ctx.attempt
    )
  end

  defp reviewable(ctx) do
    # The run has to be executing for a rejection to be able to pause it, and the
    # move is made directly so the completion events still start at sequence one.
    {:ok, %{run: run}} = commit(ctx, [{:run, {:transition_run, ctx.run, "running", []}}])
    ctx = %{ctx | run: run}

    verify(ctx)

    {:ok, %{feature: feature}} = ReviewHandoff.deliver(ctx.authority, ctx.project.id, ctx.run)

    %{ctx | feature: feature, run: current_run(ctx)}
  end

  defp subject(ctx), do: %{project: ctx.project, feature: ctx.feature}

  # The same run after its automatic budget is spent and its lease expired: the
  # one state in which reconciliation ends a run instead of retrying it.
  defp exhausted(ctx) do
    number = Retry.budget() + 1

    {:ok, _superseded} =
      commit(ctx, [{:attempt, {:transition_attempt, ctx.attempt, "superseded"}}])

    {:ok, %{run: advanced}} =
      commit(ctx, [{:run, {:advance_attempt_number, current_run(ctx), number}}])

    {:ok, %{attempt: latest}} =
      commit(ctx, [
        {:attempt,
         {:insert_attempt,
          %{
            run_id: advanced.id,
            attempt_number: number,
            continuation_reason: "automatic_retry",
            effective_revision_id: advanced.effective_revision_id,
            effective_revision_digest: advanced.effective_revision_digest,
            manifest_digest: DeliveryFixtures.digest("manifest-#{advanced.id}-#{number}"),
            fence_token: number
          }}}
      ])

    {:ok, %{attempt: dispatched}} =
      commit(ctx, [{:attempt, {:transition_attempt, latest, "dispatched"}}])

    {:ok, %{attempt: leased}} =
      commit(ctx, [
        {:attempt,
         {:claim_lease, dispatched, @worker, DateTime.add(@now, @lease_seconds, :second)}}
      ])

    %{ctx | run: advanced, attempt: leased}
  end

  defp snapshot(ctx) do
    %{
      "type" => "reconciliation_snapshot",
      "protocol_version" => WorkerProtocol.version(),
      "worker_id" => @worker,
      "observed_at" => "2026-07-29T09:00:30Z",
      "attempts" => [
        %{
          "run_id" => ctx.run.id,
          "attempt_number" => ctx.attempt.attempt_number,
          "command_id" => "cmd-#{System.unique_integer([:positive])}",
          "fence_token" => ctx.attempt.fence_token,
          "last_sequence" => ctx.attempt.last_sequence,
          "branch" => ctx.run.branch,
          "state" => "stopped"
        }
      ]
    }
  end

  defp progress_event(ctx) do
    ctx
    |> envelope(sequence: 1)
    |> Map.put("event_type", "progress")
    |> Map.put("payload", %{"summary" => "Working"})
  end

  defp blocked_event(ctx, opts) do
    payload = %{
      "question" => Keyword.fetch!(opts, :question),
      "checkpoint" => %{"stage" => "requirements"},
      "workspace_path" => "/var/sdd/workspaces/#{ctx.run.id}"
    }

    ctx
    |> envelope(opts)
    |> Map.put("event_type", Blocking.event_type())
    |> Map.put("payload", payload)
  end

  defp failure_event(ctx, opts) do
    ctx
    |> envelope(opts)
    |> Map.put("event_type", Retry.event_type())
    |> Map.put("payload", %{"reason" => Keyword.fetch!(opts, :reason)})
  end

  defp envelope(ctx, opts) do
    unique = System.unique_integer([:positive])

    %{
      "type" => "event",
      "protocol_version" => WorkerProtocol.version(),
      "event_id" => "evt-#{unique}",
      "run_id" => ctx.run.id,
      "command_id" => "cmd-#{unique}",
      "attempt_number" => ctx.attempt.attempt_number,
      "fence_token" => ctx.attempt.fence_token,
      "sequence" => Keyword.fetch!(opts, :sequence),
      "event_type" => "progress",
      "source" => "agent",
      "occurred_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "payload" => %{}
    }
  end

  defp in_development(feature) do
    {:ok, ready} =
      feature
      |> Feature.transition_changeset("ready_for_development", feature.state_version)
      |> Repo.update()

    {:ok, developing} =
      ready
      |> Feature.transition_changeset("in_development", ready.state_version)
      |> Repo.update()

    developing
  end

  defp put_env(key, value) do
    previous = Application.get_env(:sdd_orchestrator, key)
    Application.put_env(:sdd_orchestrator, key, value)

    on_exit(fn ->
      if previous do
        Application.put_env(:sdd_orchestrator, key, previous)
      else
        Application.delete_env(:sdd_orchestrator, key)
      end
    end)
  end

  defp current_participant(project, prefix) do
    identity = ParticipationFixtures.invited_identity_fixture()
    ParticipationFixtures.participant_fixture(project, identity.hosted_identity)

    ParticipationFixtures.member_profile_fixture(project, identity.account, %{
      role: "participant",
      display_name: ParticipationFixtures.unique_display_name(prefix)
    })

    identity
  end
end
