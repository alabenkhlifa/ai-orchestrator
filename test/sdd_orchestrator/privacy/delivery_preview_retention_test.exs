defmodule SddOrchestrator.Privacy.DeliveryPreviewRetentionTest do
  @moduledoc """
  Task 8 proof: terminal previews expire, their remotes permitting.

  A preview deployment is a convenience that stopped being one, and 30 days
  after it stopped the record goes. All four ways it can stop are governed, and
  each is measured by the instant that actually ended its purpose rather than
  by one shared approximation: `expires_at` for an expired preview, falling
  back to `updated_at` when the provider called it expired without ever stating
  a time; the *replacement* row's `inserted_at` for a superseded one, because
  that row's own `expires_at` answers a different question (when its preview
  stopped being reachable) and can sit either side of the supersession;
  `timeout_at` for a timed-out one, the deadline that made it time out rather
  than whenever a later poll noticed; and `updated_at` alone for a provider
  refusal, which records no expiry and reached no deadline, so the failure
  write is the only instant it has.

  Pending and ready previews are excluded by status and not by the absence of
  an instant to measure — they are what a reviewer still opens, and no age
  releases them.

  The failure this file exists to prevent is orphaning a remote. Every
  deployment has a counterpart at a preview provider, and `cleanup_state` is
  the only record of whether that counterpart was torn down. Deleting a row
  whose release is still owed, unconfirmed, or refused would leave a preview
  serving the project's content at a provider nothing can name again, so only
  `"done"` is ever released and the other three are kept however old they are.
  Both directions are proved, because a rule that released nothing would look
  identical to a safe one from the outside.

  The second failure it prevents is aborting the pass. `superseded_by_id` is
  `on_delete: :nilify_all`, and nulling it on a row still marked `"superseded"`
  violates that table's own pairing constraint, so a due row a retained
  deployment still names has to be held back rather than deleted.
  """

  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Delivery.{AgentRun, Evidence, Feature, PreviewDeployment, RunAttempt}
  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.Privacy.Retention

  @day 24 * 60 * 60
  @window 30 * @day
  @link "https://preview.example.test/branch-1"

  setup do
    context = DeliveryFixtures.delivery_project_fixture()
    feature = DeliveryFixtures.feature_fixture(context.project, context.account)
    run = DeliveryFixtures.run_fixture(context.project, feature)
    attempt = DeliveryFixtures.attempt_fixture(run)

    %{
      authority: context.workspace,
      project: context.project,
      feature: feature,
      run: run,
      attempt: attempt
    }
  end

  describe "expired previews" do
    test "releases one that expired 30 days ago and keeps a day-29 one", context do
      now = truncated_now()

      due = expired(context, DateTime.add(now, -@window, :second))
      just_inside = expired(context, DateTime.add(now, -@window + 1, :second))

      assert %{expired_delivery_previews: 1} = Retention.prune_all(now)

      refute exists?(due)
      assert exists?(just_inside)
    end

    # A provider may report `expired` without ever having stated an expiry, and
    # `Previews` only invents one for a deployment it saw become ready. The row
    # still has a server-written instant — the write that recorded the expiry,
    # or the cleanup that followed it — which is at or after the moment the
    # preview stopped being useful and so never releases the row early.
    test "measures one with no recorded expiry by its last write", context do
      now = truncated_now()

      due = undated_expired(context, DateTime.add(now, -@window, :second))
      just_inside = undated_expired(context, DateTime.add(now, -@window + 1, :second))

      assert %{expired_delivery_previews: 1} = Retention.prune_all(now)

      refute exists?(due)
      assert exists?(just_inside)
    end

    test "keeps a pending or a ready preview however old it is", context do
      now = truncated_now()
      long_ago = DateTime.add(now, -10 * @window, :second)

      pending = deployment(context, status: "pending", inserted_at: long_ago)

      # Its expiry is ancient too, which is the point: what keeps a ready
      # preview is its status, not the absence of an old timestamp on it.
      ready =
        deployment(context,
          status: "ready",
          link: @link,
          ready_at: long_ago,
          expires_at: long_ago,
          inserted_at: long_ago
        )

      assert %{expired_delivery_previews: 0} = Retention.prune_all(now)

      assert exists?(pending)
      assert exists?(ready)
    end
  end

  describe "stopped previews" do
    test "releases one the provider refused 30 days ago and keeps a day-29 one", context do
      now = truncated_now()

      due = failed(context, DateTime.add(now, -@window, :second))
      just_inside = failed(context, DateTime.add(now, -@window + 1, :second))

      assert %{expired_delivery_previews: 1} = Retention.prune_all(now)

      refute exists?(due)
      assert exists?(just_inside)
    end

    test "releases one whose deadline passed 30 days ago and keeps a day-29 one", context do
      now = truncated_now()

      due = timed_out(context, DateTime.add(now, -@window, :second))
      just_inside = timed_out(context, DateTime.add(now, -@window + 1, :second))

      assert %{expired_delivery_previews: 1} = Retention.prune_all(now)

      refute exists?(due)
      assert exists?(just_inside)
    end

    # A timed-out preview is only *recorded* as one when something next polls
    # it, which can be long after the deadline it blew. The window runs from
    # the deadline, because that is when the preview stopped being useful.
    test "measures a timed-out preview by its deadline, not by when that was noticed",
         context do
      now = truncated_now()

      due =
        timed_out(context, DateTime.add(now, -@window, :second),
          updated_at: DateTime.add(now, -@day, :second)
        )

      assert %{expired_delivery_previews: 1} = Retention.prune_all(now)

      refute exists?(due)
    end

    # The timed-out branch compares `timeout_at` with no fallback, and this is
    # the assertion that earns it: `timeout_at` is `null: false` in the table,
    # required by `request_changeset`, refused by `from_value/1`, and frozen by
    # the binding trigger, so a timed-out preview always carries the deadline
    # that made it one. A fallback was deliberately not kept — it could never
    # fire, and implying the column is nullable would be worse than saying
    # nothing. That makes this invariant load-bearing rather than decorative:
    # were the column ever made nullable, a null deadline would silently fail
    # the comparison and retain that row forever, which is precisely the
    # failure retention exists to prevent. This test fails first instead.
    test "always carries the deadline that made it time out", _context do
      assert %Postgrex.Result{rows: [["NO"]]} =
               Repo.query!("""
               SELECT is_nullable
               FROM information_schema.columns
               WHERE table_name = 'preview_deployments' AND column_name = 'timeout_at'
               """)
    end
  end

  describe "superseded previews" do
    test "releases one superseded 30 days ago and keeps a day-29 one", context do
      now = truncated_now()

      due = superseded_pair(context, DateTime.add(now, -@window, :second))
      just_inside = superseded_pair(context, DateTime.add(now, -@window + 1, :second))

      assert %{expired_delivery_previews: 1} = Retention.prune_all(now)

      refute exists?(due.superseded)
      assert exists?(just_inside.superseded)
    end

    # The replacement is the run's current preview. Releasing the row it
    # replaced must not take it with them.
    test "keeps the replacement that is still current", context do
      now = truncated_now()

      pair = superseded_pair(context, DateTime.add(now, -@window, :second))

      assert %{expired_delivery_previews: 1} = Retention.prune_all(now)

      refute exists?(pair.superseded)
      assert exists?(pair.replacement)
    end

    # The whole reason the instant is read from the replacement. This row's own
    # `expires_at` is a year old, but the deployment that replaced it was made
    # yesterday, so it only stopped being the one to look at yesterday.
    test "measures supersession by the replacement's insert, not its own expiry", context do
      now = truncated_now()

      pair =
        superseded_pair(context, DateTime.add(now, -@day, :second),
          expires_at: DateTime.add(now, -10 * @window, :second)
        )

      assert %{expired_delivery_previews: 0} = Retention.prune_all(now)

      assert exists?(pair.superseded)
      assert exists?(pair.replacement)
    end
  end

  describe "the provider-side remote" do
    # Both directions in one place. Four previews expired long ago and
    # identical but for `cleanup_state`: only the one whose provider confirmed
    # the teardown is released, and a rule that released none of them would
    # fail this test just as loudly as one that released all four.
    test "releases a settled remote and keeps every unsettled one however old", context do
      now = truncated_now()
      long_ago = DateTime.add(now, -10 * @window, :second)

      owed = expired(context, long_ago, cleanup_state: "none")
      requested = expired(context, long_ago, cleanup_state: "requested")
      refused = expired(context, long_ago, cleanup_state: "failed")
      settled = expired(context, long_ago, cleanup_state: "done")

      assert %{expired_delivery_previews: 1} = Retention.prune_all(now)

      assert exists?(owed)
      assert exists?(requested)
      assert exists?(refused)
      refute exists?(settled)
    end

    # The guard is about the remote, not about how the preview stopped, so it
    # has to hold for every terminal status rather than only the two that were
    # governed first.
    test "keeps a failed or timed-out preview whose remote is unsettled, however old", context do
      now = truncated_now()
      long_ago = DateTime.add(now, -10 * @window, :second)

      unsettled =
        Enum.flat_map(["none", "requested", "failed"], fn cleanup_state ->
          [
            failed(context, long_ago, cleanup_state: cleanup_state),
            timed_out(context, long_ago, cleanup_state: cleanup_state)
          ]
        end)

      assert %{expired_delivery_previews: 0} = Retention.prune_all(now)
      assert Enum.all?(unsettled, &exists?/1)
    end

    test "keeps a superseded preview whose provider cleanup is still owed", context do
      now = truncated_now()

      pair =
        superseded_pair(context, DateTime.add(now, -10 * @window, :second), cleanup_state: "none")

      assert %{expired_delivery_previews: 0} = Retention.prune_all(now)

      assert exists?(pair.superseded)
    end
  end

  describe "supersession links" do
    # `superseded_by_id` is `on_delete: :nilify_all`, so deleting the
    # replacement of a row that is being retained would clear that row's link
    # while its status still says `"superseded"` — a check-constraint violation
    # that aborts the whole retention pass, not one skipped row. The due row is
    # held back instead, and released on the pass where its referrer is due too.
    test "holds back a due preview a retained one still names, then releases both", context do
      now = truncated_now()
      long_ago = DateTime.add(now, -10 * @window, :second)

      # The referrer's own provider cleanup is unconfirmed, so it is retained;
      # the deployment that replaced it expired long ago and is otherwise due.
      pair =
        superseded_pair(context, long_ago,
          cleanup_state: "requested",
          replacement: [status: "expired", expires_at: long_ago]
        )

      assert %{expired_delivery_previews: 0} = Retention.prune_all(now)

      assert exists?(pair.superseded)
      assert exists?(pair.replacement)

      # The provider finally confirms the retained row's teardown. Both are now
      # due, and one statement removes them without provoking the constraint.
      confirm_cleanup(pair.superseded)

      assert %{expired_delivery_previews: 2} = Retention.prune_all(now)

      refute exists?(pair.superseded)
      refute exists?(pair.replacement)
    end
  end

  describe "the surrounding record" do
    test "leaves the feature, run, attempt, and evidence exactly as they were", context do
      now = truncated_now()

      evidence = insert_evidence(context)
      _due = expired(context, DateTime.add(now, -@window, :second))

      before = %{
        feature: Repo.get!(Feature, context.feature.id),
        run: Repo.get!(AgentRun, context.run.id),
        attempt: Repo.get!(RunAttempt, context.attempt.id),
        evidence: Repo.get!(Evidence, evidence.id)
      }

      assert %{expired_delivery_previews: 1} = Retention.prune_all(now)

      assert Repo.get!(Feature, context.feature.id) == before.feature
      assert Repo.get!(AgentRun, context.run.id) == before.run
      assert Repo.get!(RunAttempt, context.attempt.id) == before.attempt
      assert Repo.get!(Evidence, evidence.id) == before.evidence
    end
  end

  describe "idempotency" do
    test "a second pass immediately after reports nothing left to remove", context do
      now = truncated_now()

      expired(context, DateTime.add(now, -@window, :second))
      superseded_pair(context, DateTime.add(now, -@window, :second))

      assert %{expired_delivery_previews: 2} = Retention.prune_all(now)
      assert %{expired_delivery_previews: 0} = Retention.prune_all(now)
    end
  end

  defp truncated_now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp expired(context, expires_at, attrs \\ []) do
    deployment(
      context,
      Keyword.merge(
        [
          status: "expired",
          expires_at: expires_at,
          inserted_at: DateTime.add(expires_at, -@day, :second),
          updated_at: expires_at
        ],
        attrs
      )
    )
  end

  # A provider refusal: no expiry was ever recorded and the deadline it never
  # reached says nothing about it, so the failure write is the whole story.
  defp failed(context, last_write, attrs \\ []) do
    deployment(
      context,
      Keyword.merge(
        [
          status: "failed",
          inserted_at: DateTime.add(last_write, -@day, :second),
          updated_at: last_write
        ],
        attrs
      )
    )
  end

  # `timeout_at` is the deadline the request policy set, and the value
  # `Previews.settle/3` compares against to declare the timeout, so it is the
  # instant the preview stopped being useful.
  defp timed_out(context, timeout_at, attrs \\ []) do
    deployment(
      context,
      Keyword.merge(
        [
          status: "timed_out",
          inserted_at: DateTime.add(timeout_at, -300, :second),
          timeout_at: timeout_at,
          updated_at: timeout_at
        ],
        attrs
      )
    )
  end

  defp undated_expired(context, last_write) do
    deployment(context,
      status: "expired",
      expires_at: nil,
      inserted_at: DateTime.add(last_write, -@day, :second),
      updated_at: last_write
    )
  end

  # One replaced deployment and the deployment that replaced it. The
  # replacement is written first because the superseded row's foreign key names
  # it, and its `inserted_at` is the supersession instant: `Previews.start/4`
  # inserts the replacement and records the supersession link in one atomic
  # commit.
  defp superseded_pair(context, superseded_at, attrs \\ []) do
    {replacement_attrs, attrs} = Keyword.pop(attrs, :replacement, [])

    replacement =
      deployment(
        context,
        Keyword.merge([status: "pending", inserted_at: superseded_at], replacement_attrs)
      )

    superseded =
      deployment(
        context,
        Keyword.merge(
          [
            status: "superseded",
            superseded_by_id: replacement.id,
            inserted_at: DateTime.add(superseded_at, -@day, :second),
            updated_at: superseded_at
          ],
          attrs
        )
      )

    %{superseded: superseded, replacement: replacement}
  end

  # Inserted directly rather than driven through `Previews`, because every
  # instant this rule reads is server-written from the live clock and the
  # `preview_deployments_binding_frozen` trigger refuses to backdate
  # `inserted_at` or `requested_at` afterwards. The database's own check
  # constraints still judge every row this builds.
  defp deployment(context, attrs) do
    attrs = Map.new(attrs)
    inserted_at = attrs |> Map.get(:inserted_at, DateTime.utc_now()) |> usec()
    cleanup_state = Map.get(attrs, :cleanup_state, "done")
    status = Map.fetch!(attrs, :status)
    unique = System.unique_integer([:positive])

    Repo.insert!(%PreviewDeployment{
      id: Ecto.UUID.generate(),
      project_id: context.project.id,
      feature_id: context.feature.id,
      run_id: context.run.id,
      attempt_id: context.attempt.id,
      branch: context.run.branch,
      commit_sha: "commit-#{unique}",
      path: "web",
      provider: "configured-preview",
      provider_ref: "preview-provider/deployment-#{unique}",
      link: Map.get(attrs, :link),
      status: status,
      failure_reason: Map.get(attrs, :failure_reason, stopped_reason(status)),
      requested_at: inserted_at,
      ready_at: maybe_usec(Map.get(attrs, :ready_at)),
      timeout_at:
        attrs |> Map.get(:timeout_at, DateTime.add(inserted_at, 300, :second)) |> usec(),
      expires_at: maybe_usec(Map.get(attrs, :expires_at)),
      cleanup_state: cleanup_state,
      cleanup_command_id: cleanup_command_id(cleanup_state, unique),
      superseded_by_id: Map.get(attrs, :superseded_by_id),
      state_version: 1,
      inserted_at: inserted_at,
      updated_at: attrs |> Map.get(:updated_at, inserted_at) |> usec()
    })
  end

  # `status NOT IN ('failed', 'timed_out') OR failure_reason IS NOT NULL` is a
  # check constraint, so a stopped preview arrives with the token `Previews`
  # would really have written for it.
  defp stopped_reason("timed_out"), do: "preview_request_timeout"
  defp stopped_reason("failed"), do: "provider_failed"
  defp stopped_reason(_status), do: nil

  # `(cleanup_state = 'none') = (cleanup_command_id IS NULL)` is a check
  # constraint, so the pair moves together.
  defp cleanup_command_id("none", _unique), do: nil
  defp cleanup_command_id(_state, unique), do: "preview-cleanup:#{unique}"

  defp confirm_cleanup(%PreviewDeployment{id: id}) do
    {1, _} =
      Repo.update_all(
        from(deployment in PreviewDeployment, where: deployment.id == ^id),
        set: [cleanup_state: "done"]
      )

    :ok
  end

  defp insert_evidence(context) do
    content = DeliveryFixtures.png_bytes("preview-retention")

    ref =
      DeliveryFixtures.artifact_fixture(context.authority, context.project.id, content: content)

    Repo.insert!(%Evidence{
      id: Ecto.UUID.generate(),
      project_id: context.project.id,
      feature_id: context.feature.id,
      run_id: context.run.id,
      command_id: "cmd-#{System.unique_integer([:positive])}",
      kind: "screenshot",
      name: "checkout screen",
      outcome: "passed",
      duration_ms: 12,
      branch: context.run.branch,
      commit_sha: "a1b2c3d4e5f6a7b8c9d0",
      source: "worker",
      recorded_at: usec(DateTime.utc_now()),
      digest: DeliveryFixtures.content_digest(content),
      redacted: false,
      artifact_ref: ref,
      state_version: 1
    })
  end

  defp exists?(%PreviewDeployment{id: id}), do: not is_nil(Repo.get(PreviewDeployment, id))

  # `DateTime.truncate/2` only ever lowers precision, so it cannot widen a
  # second-precision fixture time into the microsecond precision every column
  # on this table declares. Adding zero microseconds does.
  defp usec(value), do: DateTime.add(value, 0, :microsecond)

  defp maybe_usec(nil), do: nil
  defp maybe_usec(value), do: usec(value)
end
