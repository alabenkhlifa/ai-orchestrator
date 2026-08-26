defmodule SddOrchestrator.Privacy.DeliveryDevicePreviewRetentionTest do
  @moduledoc """
  Task 11 proof: device-authoritative terminal previews expire, their remotes
  permitting.

  The device half of the lifecycle Task 8 proved for the hosted store, on the
  same 30-day window, the same terminal-status boundary, and the same guard
  that decides everything: a preview deployment has a counterpart at a
  provider, and `cleanup_state` is the only record of whether that counterpart
  was torn down. Only `"done"` means it was. `"none"` is a release that was
  never asked for rather than nothing owed, `"requested"` is a command made
  durable that the provider never confirmed, and `"failed"` is a refusal —
  removing the record in any of those three leaves a preview possibly still
  serving the project's content at a provider nothing can name again. That is a
  worse outcome than keeping a record, so it is proved in both directions and
  for more than one status, because the guard is about the remote and not about
  how the preview stopped.

  What makes this its own proof rather than a repeat is what a device record
  can be dated by. `PreviewDeployment.to_value/1` emits `requested_at`,
  `ready_at`, `timeout_at`, and `expires_at` and no Ecto timestamp at all, so
  the hosted rule's `COALESCE(expires_at, updated_at)` fallback and its
  `replacement.inserted_at` do not survive the seam. An expired preview is
  measured by `expires_at`, a timed-out one by the deadline `from_value/1`
  refuses to decode without, and a superseded one by its *replacement's*
  `requested_at` — the device-visible instant of the write the hosted half
  measures as `inserted_at`, made in the same atomic commit as the supersession
  link. A provider refusal, and an expiry a provider never stated, have no
  instant of their own left on this seam, so they are retained rather than
  released against an instant that answers a different question; both are
  pinned here so that a later change measuring them by `requested_at` or
  `timeout_at` fails loudly instead of quietly deleting records early.

  Two further properties are device-specific. Eligibility is decided entirely
  inside the device authority, so a sweep of a device project must leave the
  hosted tables untouched — including the project row a device-authoritative
  project never has. And removal is a tombstone put, never a key delete,
  because the delivery seam applies puts and nothing else.

  The failure the hold-back tests exist to prevent is the device form of the
  hazard Task 8 met as a check-constraint violation. Nothing here can abort a
  pass, but a retained record's supersession instant *is* its replacement's
  `requested_at`, so removing the replacement of a record that is being kept
  would strand it: once its own cleanup is finally confirmed, the instant that
  would have released it is gone and it would be retained forever.
  """

  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Delivery.PreviewDeployment
  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.DeviceStore.Local
  alias SddOrchestrator.Privacy.Retention
  alias SddOrchestrator.Projects.Project

  @day 24 * 60 * 60
  @window 30 * @day
  @link "https://preview.example.test/branch-1"

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "device-preview-retention-#{System.unique_integer([:positive])}/store.dets"
      )

    start_supervised!({Local, path: path})
    on_exit(fn -> File.rm_rf!(Path.dirname(path)) end)

    {:ok, workspace} = Devices.establish_workspace()

    {:ok, project} =
      Devices.register_project(%{
        name: "Device preview retention project",
        repository_fingerprint:
          "device-preview-retention-fingerprint-#{System.unique_integer([:positive])}",
        status: "connected",
        idempotency_key: Ecto.UUID.generate()
      })

    %{
      project: project,
      workspace: workspace,
      feature_id: Ecto.UUID.generate(),
      run_id: Ecto.UUID.generate(),
      attempt_id: Ecto.UUID.generate(),
      branch: "sdd/device-feature-#{System.unique_integer([:positive])}"
    }
  end

  describe "expired previews" do
    test "releases one that expired 30 days ago and keeps a day-29 one", context do
      now = truncated_now()

      due = expired(context, DateTime.add(now, -@window, :second))
      just_inside = expired(context, DateTime.add(now, -@window + 1, :second))

      assert %{expired_device_delivery_previews: 1} = Retention.prune_all(now)

      refute exists?(context, due)
      assert exists?(context, just_inside)
    end

    # The hosted rule falls back to the row's last write for a provider that
    # reported `expired` without ever stating a time. No last write survives
    # `to_value/1`, and every other instant this record carries belongs to the
    # request rather than to the expiry, so nothing is invented for it: the
    # record is kept.
    test "keeps one whose provider never stated an expiry, however old", context do
      now = truncated_now()

      undated = undated_expired(context, DateTime.add(now, -10 * @window, :second))

      assert %{expired_device_delivery_previews: 0} = Retention.prune_all(now)

      assert exists?(context, undated)
    end

    test "keeps a pending or a ready preview however old it is", context do
      now = truncated_now()
      long_ago = DateTime.add(now, -10 * @window, :second)

      pending = put_preview!(context, status: "pending", requested_at: long_ago)

      # Its expiry is ancient too, which is the point: what keeps a ready
      # preview is its status, not the absence of an old instant on it.
      ready =
        put_preview!(context,
          status: "ready",
          link: @link,
          requested_at: long_ago,
          ready_at: long_ago,
          expires_at: long_ago
        )

      assert %{expired_device_delivery_previews: 0} = Retention.prune_all(now)

      assert exists?(context, pending)
      assert exists?(context, ready)
    end
  end

  describe "stopped previews" do
    test "releases one whose deadline passed 30 days ago and keeps a day-29 one", context do
      now = truncated_now()

      due = timed_out(context, DateTime.add(now, -@window, :second))
      just_inside = timed_out(context, DateTime.add(now, -@window + 1, :second))

      assert %{expired_device_delivery_previews: 1} = Retention.prune_all(now)

      refute exists?(context, due)
      assert exists?(context, just_inside)
    end

    # The deadline, not the poll that noticed it. The request that blew it was
    # made five minutes earlier and the record has carried it ever since.
    test "measures a timed-out preview by its deadline", context do
      now = truncated_now()

      # Requested inside the window; only the deadline it blew is 30 days old.
      due =
        timed_out(context, DateTime.add(now, -@window, :second),
          requested_at: DateTime.add(now, -@window - 300, :second)
        )

      assert %{expired_device_delivery_previews: 1} = Retention.prune_all(now)

      refute exists?(context, due)
    end

    # The one status this seam cannot date at all. A provider refusal records no
    # expiry, never became ready, and reached no deadline of its own, so the
    # `updated_at` the hosted rule measures it by has no device counterpart.
    # `requested_at` and `timeout_at` both belong to the request and can precede
    # the refusal by any amount, so measuring from either would delete the
    # record before the thirty days it is owed have run. It is kept instead, and
    # this test is what fails if a later change decides otherwise.
    test "keeps a provider refusal however old, because no instant of it survives the seam",
         context do
      now = truncated_now()

      refused = failed(context, DateTime.add(now, -10 * @window, :second))

      assert %{expired_device_delivery_previews: 0} = Retention.prune_all(now)

      assert exists?(context, refused)
    end
  end

  describe "superseded previews" do
    test "releases one superseded 30 days ago and keeps a day-29 one", context do
      now = truncated_now()

      due = superseded_pair(context, DateTime.add(now, -@window, :second))
      just_inside = superseded_pair(context, DateTime.add(now, -@window + 1, :second))

      assert %{expired_device_delivery_previews: 1} = Retention.prune_all(now)

      refute exists?(context, due.superseded)
      assert exists?(context, just_inside.superseded)
    end

    test "keeps the replacement that is still current", context do
      now = truncated_now()

      pair = superseded_pair(context, DateTime.add(now, -@window, :second))

      assert %{expired_device_delivery_previews: 1} = Retention.prune_all(now)

      refute exists?(context, pair.superseded)
      assert exists?(context, pair.replacement)
    end

    # The whole reason the instant is read from the replacement. This record's
    # own expiry is a year old, but the deployment that replaced it was
    # requested yesterday, so it only stopped being the one to look at
    # yesterday.
    test "measures supersession by the replacement's request, not its own expiry", context do
      now = truncated_now()

      pair =
        superseded_pair(context, DateTime.add(now, -@day, :second),
          expires_at: DateTime.add(now, -10 * @window, :second)
        )

      assert %{expired_device_delivery_previews: 0} = Retention.prune_all(now)

      assert exists?(context, pair.superseded)
      assert exists?(context, pair.replacement)
    end

    # The device store has no foreign key, so a record can name a replacement
    # the store does not hold. Its supersession cannot be placed against the
    # window at all, and the device evidence rule settles the same case the same
    # way: it is kept rather than released against a guess.
    test "keeps one whose replacement the store does not hold, however old", context do
      now = truncated_now()

      orphaned =
        put_preview!(context,
          status: "superseded",
          superseded_by_id: Ecto.UUID.generate(),
          requested_at: DateTime.add(now, -10 * @window, :second)
        )

      assert %{expired_device_delivery_previews: 0} = Retention.prune_all(now)

      assert exists?(context, orphaned)
    end
  end

  describe "the provider-side remote" do
    # Both directions in one place. Four previews expired long ago and identical
    # but for `cleanup_state`: only the one whose provider confirmed the
    # teardown is released, and a rule that released none of them would fail
    # this test just as loudly as one that released all four.
    test "releases a settled remote and keeps every unsettled one however old", context do
      now = truncated_now()
      long_ago = DateTime.add(now, -10 * @window, :second)

      owed = expired(context, long_ago, cleanup_state: "none")
      requested = expired(context, long_ago, cleanup_state: "requested")
      refused = expired(context, long_ago, cleanup_state: "failed")
      settled = expired(context, long_ago, cleanup_state: "done")

      assert %{expired_device_delivery_previews: 1} = Retention.prune_all(now)

      assert exists?(context, owed)
      assert exists?(context, requested)
      assert exists?(context, refused)
      refute exists?(context, settled)
    end

    # The guard is about the remote, not about how the preview stopped, so it
    # has to hold for every terminal status a device record can be dated by
    # rather than only for the one governed first.
    test "keeps a timed-out or superseded preview whose remote is unsettled, however old",
         context do
      now = truncated_now()
      long_ago = DateTime.add(now, -10 * @window, :second)

      unsettled =
        Enum.flat_map(["none", "requested", "failed"], fn cleanup_state ->
          [
            timed_out(context, long_ago, cleanup_state: cleanup_state),
            superseded_pair(context, long_ago, cleanup_state: cleanup_state).superseded
          ]
        end)

      assert %{expired_device_delivery_previews: 0} = Retention.prune_all(now)
      assert Enum.all?(unsettled, &exists?(context, &1))
    end
  end

  describe "supersession links" do
    # The device form of the hazard the hosted rule meets as a check-constraint
    # violation. Nothing here can abort a pass, but a retained record's
    # supersession instant *is* its replacement's `requested_at`: tombstoning
    # the replacement of a record that is being kept would leave that record
    # permanently undatable, so once its own cleanup was finally confirmed it
    # could never be released at all. The replacement is held back instead, and
    # both go on the pass where the referrer is due too.
    test "holds back a releasable preview a retained one still names, then releases both",
         context do
      now = truncated_now()
      long_ago = DateTime.add(now, -10 * @window, :second)

      # The referrer's own provider cleanup is unconfirmed, so it is retained;
      # the deployment that replaced it expired long ago and is otherwise due.
      pair =
        superseded_pair(context, long_ago,
          cleanup_state: "requested",
          replacement: [status: "expired", expires_at: long_ago, cleanup_state: "done"]
        )

      assert %{expired_device_delivery_previews: 0} = Retention.prune_all(now)

      assert exists?(context, pair.superseded)
      assert exists?(context, pair.replacement)

      # The provider finally confirms the retained record's teardown. Both are
      # now due, and neither is left naming a record that is gone.
      confirm_cleanup!(context, pair.superseded)

      assert %{expired_device_delivery_previews: 2} = Retention.prune_all(now)

      refute exists?(context, pair.superseded)
      refute exists?(context, pair.replacement)
    end

    # Holding one record back makes it a retainer in its own right, which is why
    # the held-back set is closed rather than filtered once. Filtering once
    # would keep the middle of this chain and delete its end, stranding the
    # middle exactly as deleting the replacement would have stranded the head.
    test "holds back a whole chain rather than stranding its middle", context do
      now = truncated_now()
      long_ago = DateTime.add(now, -10 * @window, :second)

      last = expired(context, long_ago)

      middle =
        put_preview!(context,
          status: "superseded",
          superseded_by_id: last.id,
          requested_at: DateTime.add(long_ago, -@day, :second)
        )

      head =
        put_preview!(context,
          status: "superseded",
          superseded_by_id: middle.id,
          requested_at: DateTime.add(long_ago, -2 * @day, :second),
          cleanup_state: "requested"
        )

      assert %{expired_device_delivery_previews: 0} = Retention.prune_all(now)

      assert exists?(context, head)
      assert exists?(context, middle)
      assert exists?(context, last)

      confirm_cleanup!(context, head)

      assert %{expired_device_delivery_previews: 3} = Retention.prune_all(now)

      refute exists?(context, head)
      refute exists?(context, middle)
      refute exists?(context, last)
    end
  end

  describe "the device seam" do
    # The delivery seam applies puts and nothing else, so removal is a tombstone
    # rather than a key delete. The key is still there and now carries the bare
    # fact that it is no longer a preview: no provider reference, no link, no
    # branch, no commit.
    test "tombstones the key rather than deleting it", context do
      now = truncated_now()

      due = expired(context, DateTime.add(now, -@window, :second))

      assert %{expired_device_delivery_previews: 1} = Retention.prune_all(now)

      assert {:ok, value} = Devices.get_delivery(context.project.id, :preview, due.id)
      assert value == %{"deleted" => true}
      assert PreviewDeployment.from_value(value) == {:error, :invalid_preview_value}

      # The tombstone is what the listing now holds under that key, so every
      # reader treats the record as absent.
      assert value in Devices.list_delivery(context.project.id, :preview)
    end

    test "decides eligibility inside the device authority, creating no hosted copy", context do
      now = truncated_now()

      # The project this rule sweeps is the one registered under the device
      # workspace, which has no hosted project row at all.
      assert context.project.workspace_id == context.workspace.id

      due = expired(context, DateTime.add(now, -@window, :second))
      _kept = failed(context, DateTime.add(now, -10 * @window, :second))

      assert %{expired_device_delivery_previews: 1} = Retention.prune_all(now)

      refute exists?(context, due)

      # Nothing about this project was read from or written to the hosted store
      # to decide what to prune, so after a full sweep the hosted table this
      # rule's counterpart governs is still empty — including the project row
      # itself, which a device-authoritative project never has.
      assert Repo.aggregate(PreviewDeployment, :count) == 0
      assert Repo.aggregate(Project, :count) == 0
    end
  end

  describe "availability and idempotency" do
    test "an unreachable device store pauses only its own rule", context do
      now = truncated_now()

      expired(context, DateTime.add(now, -@window, :second))

      hosted = hosted_due_preview!(now)

      stop_supervised!(Local)

      # The device rule reports zero rather than raising, and the pass carries
      # on: the hosted half of the very same lifecycle still releases its own
      # due deployment in the same call.
      assert %{expired_device_delivery_previews: 0, expired_delivery_previews: 1} =
               Retention.prune_all(now)

      refute Repo.get(PreviewDeployment, hosted.id)
    end

    test "a second pass immediately after reports nothing left to remove", context do
      now = truncated_now()

      expired(context, DateTime.add(now, -@window, :second))
      timed_out(context, DateTime.add(now, -@window, :second))
      superseded_pair(context, DateTime.add(now, -@window, :second))

      assert %{expired_device_delivery_previews: 3} = Retention.prune_all(now)
      assert %{expired_device_delivery_previews: 0} = Retention.prune_all(now)
    end
  end

  defp truncated_now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp expired(context, expires_at, attrs \\ []) do
    put_preview!(
      context,
      Keyword.merge(
        [
          status: "expired",
          expires_at: expires_at,
          requested_at: DateTime.add(expires_at, -@day, :second)
        ],
        attrs
      )
    )
  end

  # A provider that reported `expired` without ever stating a time. `Previews`
  # only invents an expiry for a deployment it saw become ready, so this record
  # genuinely carries none.
  defp undated_expired(context, requested_at, attrs \\ []) do
    put_preview!(
      context,
      Keyword.merge([status: "expired", expires_at: nil, requested_at: requested_at], attrs)
    )
  end

  # `timeout_at` is the deadline the request policy set and the value `Previews`
  # compares against to declare the timeout, so it is the instant the preview
  # stopped being useful.
  defp timed_out(context, timeout_at, attrs \\ []) do
    put_preview!(
      context,
      Keyword.merge(
        [
          status: "timed_out",
          timeout_at: timeout_at,
          requested_at: DateTime.add(timeout_at, -300, :second)
        ],
        attrs
      )
    )
  end

  # A provider refusal: no expiry was ever recorded, it never became ready, and
  # the deadline it never reached says nothing about it.
  defp failed(context, requested_at, attrs \\ []) do
    put_preview!(context, Keyword.merge([status: "failed", requested_at: requested_at], attrs))
  end

  # One replaced deployment and the deployment that replaced it. The replacement
  # is written first because the superseded record names it, and its
  # `requested_at` is the supersession instant: `Previews.start/4` writes the
  # replacement's request and the supersession link in one atomic commit.
  defp superseded_pair(context, superseded_at, attrs \\ []) do
    {replacement_attrs, attrs} = Keyword.pop(attrs, :replacement, [])

    replacement =
      put_preview!(
        context,
        Keyword.merge(
          [status: "pending", cleanup_state: "none", requested_at: superseded_at],
          replacement_attrs
        )
      )

    superseded =
      put_preview!(
        context,
        Keyword.merge(
          [
            status: "superseded",
            superseded_by_id: replacement.id,
            requested_at: DateTime.add(superseded_at, -@day, :second)
          ],
          attrs
        )
      )

    %{superseded: superseded, replacement: replacement}
  end

  # Written straight through the delivery seam rather than through `Previews`,
  # because every instant this rule reads would otherwise be written from the
  # live clock. `PreviewDeployment.to_value/1` is what the worker really stores,
  # so the record under test is the exact value shape the rule has to judge.
  defp put_preview!(context, attrs) do
    attrs = Map.new(attrs)
    unique = System.unique_integer([:positive])
    status = Map.fetch!(attrs, :status)
    requested_at = Map.get(attrs, :requested_at, truncated_now())
    cleanup_state = Map.get(attrs, :cleanup_state, "done")
    superseded_by_id = Map.get(attrs, :superseded_by_id)

    deployment = %PreviewDeployment{
      id: Ecto.UUID.generate(),
      project_id: context.project.id,
      feature_id: context.feature_id,
      run_id: context.run_id,
      attempt_id: context.attempt_id,
      branch: context.branch,
      commit_sha: "commit-#{unique}",
      path: "web",
      provider: "configured-preview",
      provider_ref: "preview-provider/deployment-#{unique}",
      link: Map.get(attrs, :link),
      status: status,
      failure_reason: Map.get(attrs, :failure_reason, stopped_reason(status)),
      requested_at: requested_at,
      ready_at: Map.get(attrs, :ready_at),
      timeout_at: Map.get(attrs, :timeout_at, DateTime.add(requested_at, 300, :second)),
      expires_at: Map.get(attrs, :expires_at),
      cleanup_state: cleanup_state,
      cleanup_command_id: cleanup_command_id(cleanup_state, unique),
      superseded_by_id: superseded_by_id,
      # A supersession is a second write to the record, exactly as the worker
      # would have applied it, so the tombstone has a real version to match.
      state_version: if(is_nil(superseded_by_id), do: 1, else: 2)
    }

    {:ok, _applied} =
      Devices.commit_delivery(context.project.id, [
        {:put, :preview, deployment.id, PreviewDeployment.to_value(deployment), nil}
      ])

    deployment
  end

  # A stopped preview always says why, so the record carries the token
  # `Previews` would really have written for it.
  defp stopped_reason("timed_out"), do: "preview_request_timeout"
  defp stopped_reason("failed"), do: "provider_failed"
  defp stopped_reason(_status), do: nil

  # The cleanup command is recorded before the provider is called, so a
  # cleanup-bearing state always names one and `"none"` never does.
  defp cleanup_command_id("none", _unique), do: nil
  defp cleanup_command_id(_state, unique), do: "preview-cleanup:#{unique}"

  # The provider confirming a teardown the control plane had already recorded:
  # one further write to the same record, carrying the version the sweep will
  # then have to match.
  defp confirm_cleanup!(context, %PreviewDeployment{} = deployment) do
    settled = %{
      deployment
      | cleanup_state: "done",
        cleanup_command_id:
          deployment.cleanup_command_id ||
            "preview-cleanup:#{System.unique_integer([:positive])}",
        state_version: deployment.state_version + 1
    }

    {:ok, _applied} =
      Devices.commit_delivery(context.project.id, [
        {:put, :preview, settled.id, PreviewDeployment.to_value(settled),
         deployment.state_version}
      ])

    settled
  end

  defp exists?(context, %PreviewDeployment{id: id}) do
    case Devices.get_delivery(context.project.id, :preview, id) do
      {:ok, value} -> match?({:ok, _record}, PreviewDeployment.from_value(value))
      {:error, :not_found} -> false
    end
  end

  # One hosted deployment Task 8's rule is due to release, so the
  # unreachable-device proof can show the pass continuing rather than only that
  # it did not raise. Nothing here touches the device store.
  defp hosted_due_preview!(now) do
    hosted = DeliveryFixtures.delivery_project_fixture()
    feature = DeliveryFixtures.feature_fixture(hosted.project, hosted.account)
    run = DeliveryFixtures.run_fixture(hosted.project, feature)
    attempt = DeliveryFixtures.attempt_fixture(run)
    expires_at = DateTime.add(now, -@window, :second)
    requested_at = DateTime.add(expires_at, -@day, :second)
    unique = System.unique_integer([:positive])

    Repo.insert!(%PreviewDeployment{
      id: Ecto.UUID.generate(),
      project_id: hosted.project.id,
      feature_id: feature.id,
      run_id: run.id,
      attempt_id: attempt.id,
      branch: run.branch,
      commit_sha: "commit-#{unique}",
      path: "web",
      provider: "configured-preview",
      provider_ref: "preview-provider/hosted-#{unique}",
      status: "expired",
      requested_at: usec(requested_at),
      timeout_at: usec(DateTime.add(requested_at, 300, :second)),
      expires_at: usec(expires_at),
      cleanup_state: "done",
      cleanup_command_id: "preview-cleanup:#{unique}",
      state_version: 1,
      inserted_at: usec(requested_at),
      updated_at: usec(expires_at)
    })
  end

  # `DateTime.truncate/2` only ever lowers precision, so it cannot widen a
  # second-precision fixture time into the microsecond precision every column on
  # the hosted table declares. Adding zero microseconds does. The device seam
  # needs none of this: it carries ISO8601 strings, not Ecto values.
  defp usec(value), do: DateTime.add(value, 0, :microsecond)
end
