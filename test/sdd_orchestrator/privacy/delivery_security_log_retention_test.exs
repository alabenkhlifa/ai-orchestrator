defmodule SddOrchestrator.Privacy.DeliverySecurityLogRetentionTest do
  @moduledoc """
  specs/19 Task 5 proof: guided-delivery operational-security records expire at
  30 days, and expiring them changes nothing authoritative.

  A `DeliverySecurityEvent` is fixed, minimized evidence of one
  security-relevant occurrence on the Slice 07 boundary, not a durable record.
  It is deleted 30 days after its own `occurred_at` through
  `SddOrchestrator.Privacy.DeliverySecurityLog`'s retention-capable local sink,
  registered in `SddOrchestrator.Privacy.Retention` as a rule like any other:
  its own advisory-lock key, its own durable outcome, its own zeros when it is
  contended.

  The failure this file exists to prevent is a retention rule that reaches past
  its own table. The log is *about* project access decisions, worker commands,
  adapter refusals, and the evidence boundary — so the interesting question is
  not whether the events go, but whether anything they describe goes with them.
  It is asked by consequence: real delivery state is built, the whole database
  is photographed, the sweep runs and genuinely deletes, and the photograph is
  compared. `occurred_at` is the only selector — the row carries no project
  identifier to filter on, and all five allowlisted event types share one
  purpose and one window — so a selector that touched anything else would have
  to be visible here.
  """

  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.AccountsFixtures
  alias SddOrchestrator.Delivery.{AgentRun, ArtifactStore, Evidence, Feature, RunAttempt}
  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.Participation.{ProjectMemberProfile, ProjectParticipant}
  alias SddOrchestrator.Privacy.{DeliverySecurityEvent, DeliverySecurityLog}
  alias SddOrchestrator.Privacy.{DeliverySupportAccess, DeliverySupportElevation}
  alias SddOrchestrator.Privacy.{Retention, RetentionRuleOutcome}
  alias SddOrchestrator.Projects.Project

  @rule :expired_delivery_security_events

  @day 24 * 60 * 60
  @window 30 * @day

  # The two tables this task is allowed to change: its own sink, and the
  # durable per-rule outcome every pass rewrites by design. Everything else in
  # the database must come out of a sweep byte-identical, which is what the
  # snapshot below asserts. `schema_migrations` is excluded as infrastructure,
  # not as state.
  @mutable_tables ~w(delivery_security_events retention_rule_outcomes schema_migrations)

  describe "30-day expiry" do
    test "deletes an event at the 30-day boundary and keeps a day-29 event" do
      now = truncated_now()

      due = event_fixture(occurred_at: DateTime.add(now, -@window, :second))
      just_inside = event_fixture(occurred_at: DateTime.add(now, -@window + 1, :second))

      assert %{@rule => 1} = Retention.prune_all(now)

      refute Repo.get(DeliverySecurityEvent, due.id)
      assert Repo.get(DeliverySecurityEvent, just_inside.id)
    end

    test "prune/1 reports the real deleted count directly" do
      now = truncated_now()
      cutoff = DateTime.add(now, -@window, :second)

      event_fixture(occurred_at: cutoff)
      event_fixture(occurred_at: cutoff)
      event_fixture(occurred_at: DateTime.add(now, -@window + 1, :second))

      assert DeliverySecurityLog.prune(cutoff) == 2
      assert Repo.aggregate(DeliverySecurityEvent, :count) == 1
    end

    test "re-running the sweep is idempotent and reports nothing left to remove" do
      now = truncated_now()
      event_fixture(occurred_at: DateTime.add(now, -@window, :second))

      assert %{@rule => 1} = Retention.prune_all(now)
      assert %{@rule => 0} = Retention.prune_all(now)
      assert Repo.aggregate(DeliverySecurityEvent, :count) == 0
    end

    test "an event not yet due in one pass is reconciled once it crosses the boundary" do
      now = truncated_now()

      due_soon = event_fixture(occurred_at: DateTime.add(now, -@window + 60, :second))

      assert %{@rule => 0} = Retention.prune_all(now)
      assert Repo.get(DeliverySecurityEvent, due_soon.id)

      later = DateTime.add(now, 120, :second)

      assert %{@rule => 1} = Retention.prune_all(later)
      refute Repo.get(DeliverySecurityEvent, due_soon.id)
    end

    # No event type is privileged. `emit/3` is the real write path, so this
    # also proves the emitted rows are the ones the window selects rather than
    # hand-built fixtures that merely resemble them.
    test "every allowlisted event type expires alike, and none is selected separately" do
      now = truncated_now()
      types = DeliverySecurityLog.event_types()

      assert length(types) == 5

      for type <- types do
        assert :ok =
                 DeliverySecurityLog.emit(type, :failed,
                   occurred_at: DateTime.add(now, -@window, :second)
                 )

        assert :ok =
                 DeliverySecurityLog.emit(type, :failed,
                   occurred_at: DateTime.add(now, -@window + 1, :second)
                 )
      end

      assert Repo.aggregate(DeliverySecurityEvent, :count) == 2 * length(types)

      assert %{@rule => deleted} = Retention.prune_all(now)
      assert deleted == length(types)

      survivors = Repo.all(DeliverySecurityEvent)

      assert length(survivors) == length(types)
      assert survivors |> Enum.map(& &1.event_type) |> Enum.sort() == Enum.sort(types)
    end
  end

  describe "the rule, registered like every other" do
    test "claims its own key from the reserved band, distinct from every other rule's" do
      key = Retention.rule_advisory_lock_key(@rule)

      assert is_integer(key)
      assert key in Retention.rule_advisory_lock_band()

      other_keys =
        (Retention.rule_names() -- [@rule])
        |> Enum.map(&Retention.rule_advisory_lock_key/1)

      refute key in other_keys
    end

    test "records a durable outcome, rewritten in place on every pass" do
      now = truncated_now()
      event_fixture(occurred_at: DateTime.add(now, -@window, :second))

      assert %{@rule => 1} = Retention.prune_all(now)

      first = Repo.get_by!(RetentionRuleOutcome, rule: @rule)

      assert first.state == :succeeded
      assert first.failure_class == nil
      assert first.attempt_count == 1
      assert DateTime.compare(first.succeeded_at, now) == :eq
      assert {:ok, _fresh} = Ecto.UUID.cast(first.correlation_id)

      assert %{@rule => 0} = Retention.prune_all(now)

      second = Repo.get_by!(RetentionRuleOutcome, rule: @rule)

      assert second.id == first.id
      assert second.state == :succeeded
      assert second.attempt_count == 2
      assert second.correlation_id != first.correlation_id

      assert Repo.aggregate(from(o in RetentionRuleOutcome, where: o.rule == ^@rule), :count) == 1
    end

    # The rule name is closed in three places — the runner's own table, the
    # outcome schema's `Ecto.Enum`, and the `retention_rule_outcomes_rule_allowed`
    # check constraint. The row above only exists because all three agree; this
    # asserts the two readable ones directly so a future drift names itself.
    test "the rule name is in the closed vocabulary the outcome record enforces" do
      assert @rule in Retention.rule_names()
      assert @rule in RetentionRuleOutcome.rules()
      assert Enum.sort(Retention.rule_names()) == RetentionRuleOutcome.rules()
    end

    test "a contended rule reports zero, deletes nothing, and records nothing" do
      now = truncated_now()
      due = event_fixture(occurred_at: DateTime.add(now, -@window, :second))
      key = Retention.rule_advisory_lock_key(@rule)
      connection = raw_connection()

      assert %Postgrex.Result{rows: [[:void]]} =
               Postgrex.query!(connection, "SELECT pg_advisory_lock($1)", [key])

      assert %{@rule => 0} = Retention.prune_all(now)

      assert Repo.get(DeliverySecurityEvent, due.id)

      # The instance holding the lock is the one doing the work and the one
      # that will record it, so the contended pass leaves no account of its
      # own behind at all.
      refute Repo.get_by(RetentionRuleOutcome, rule: @rule)

      # A rule that ran in the very same pass still recorded its own outcome.
      assert %{state: :succeeded} =
               Repo.get_by!(RetentionRuleOutcome, rule: :authorization_attempts)

      assert %Postgrex.Result{rows: [[true]]} =
               Postgrex.query!(connection, "SELECT pg_advisory_unlock($1)", [key])

      assert %{@rule => 1} = Retention.prune_all(now)
      refute Repo.get(DeliverySecurityEvent, due.id)

      assert %{state: :succeeded, attempt_count: 1} =
               Repo.get_by!(RetentionRuleOutcome, rule: @rule)
    end
  end

  describe "nothing authoritative changes" do
    setup :delivery_state

    test "a sweep that deletes events leaves authorization, delivery, and evidence state as it was",
         state do
      now = truncated_now()

      for type <- DeliverySecurityLog.event_types() do
        assert :ok =
                 DeliverySecurityLog.emit(type, :failed,
                   occurred_at: DateTime.add(now, -@window, :second)
                 )
      end

      before_project = Repo.get!(Project, state.project.id)
      before_participants = sorted_by_id(ProjectParticipant)
      before_profiles = sorted_by_id(ProjectMemberProfile)
      before_feature = Repo.get!(Feature, state.feature.id)
      before_run = Repo.get!(AgentRun, state.run.id)
      before_attempt = Repo.get!(RunAttempt, state.attempt.id)
      before_evidence = Repo.get!(Evidence, state.evidence.id)
      before_elevation = Repo.get!(DeliverySupportElevation, state.elevation.id)

      # Everything at once, so a rule that reached into a table this test never
      # thought to name would still be caught.
      before_database = database_snapshot()

      assert %{@rule => 5} = Retention.prune_all(now)
      assert Repo.aggregate(DeliverySecurityEvent, :count) == 0

      # Project authorization and access state.
      assert Repo.get!(Project, state.project.id) == before_project
      assert sorted_by_id(ProjectParticipant) == before_participants
      assert sorted_by_id(ProjectMemberProfile) == before_profiles
      assert Enum.all?(before_participants, &(&1.state == "active"))

      # Feature and run state.
      assert Repo.get!(Feature, state.feature.id) == before_feature
      assert Repo.get!(AgentRun, state.run.id) == before_run
      assert Repo.get!(RunAttempt, state.attempt.id) == before_attempt

      # Accepted evidence, and the bytes it still names.
      assert Repo.get!(Evidence, state.evidence.id) == before_evidence

      assert {:ok, artifact} =
               ArtifactStore.fetch(state.authority, state.project.id, state.artifact_ref)

      assert artifact.content == state.artifact_content

      # Every other `delivery_*` table.
      assert Repo.get!(DeliverySupportElevation, state.elevation.id) == before_elevation

      assert delivery_tables() == ["delivery_security_events", "delivery_support_elevations"]

      # And the whole database, table by table and row by row.
      assert database_snapshot() == before_database
    end

    test "a sweep with nothing due is inert for exactly the same reason", state do
      now = truncated_now()

      event_fixture(occurred_at: DateTime.add(now, -@window + 1, :second))

      before_database = database_snapshot()

      assert %{@rule => 0} = Retention.prune_all(now)
      assert Repo.aggregate(DeliverySecurityEvent, :count) == 1

      assert database_snapshot() == before_database
      assert Repo.get!(Evidence, state.evidence.id).outcome == "passed"
    end
  end

  # Real delivery state: an owned project with an active participant and both
  # member profiles, a feature, a run and its current attempt, one item of
  # accepted evidence with genuinely stored bytes, and a support elevation so
  # the other `delivery_*` table is populated rather than trivially empty.
  defp delivery_state(_context) do
    context = DeliveryFixtures.delivery_project_fixture()
    feature = DeliveryFixtures.feature_fixture(context.project, context.account)

    %{run: run, attempt: attempt} =
      DeliveryFixtures.run_with_attempt_fixture(context.project, feature)

    content = DeliveryFixtures.png_bytes("accepted")

    ref =
      DeliveryFixtures.artifact_fixture(context.workspace, context.project.id, content: content)

    evidence =
      Repo.insert!(%Evidence{
        id: Ecto.UUID.generate(),
        project_id: context.project.id,
        feature_id: feature.id,
        run_id: run.id,
        command_id: "cmd-#{System.unique_integer([:positive])}",
        kind: "screenshot",
        name: "checkout screen",
        outcome: "passed",
        duration_ms: 12,
        branch: run.branch,
        commit_sha: "a1b2c3d4e5f6a7b8c9d0",
        source: "worker",
        recorded_at: DateTime.add(DateTime.utc_now(), 0, :microsecond),
        digest: DeliveryFixtures.content_digest(content),
        redacted: false,
        artifact_ref: ref,
        state_version: 1
      })

    {:ok, elevation} =
      DeliverySupportAccess.issue(%{
        operations_account_id: AccountsFixtures.account_fixture().id,
        project_id: context.project.id,
        purpose: :incident_diagnosis,
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      })

    %{
      authority: context.workspace,
      project: context.project,
      feature: feature,
      run: run,
      attempt: attempt,
      evidence: evidence,
      artifact_ref: ref,
      artifact_content: content,
      elevation: elevation
    }
  end

  defp event_fixture(attrs) do
    attrs = Map.new(attrs)

    defaults = %{
      event_type: :delivery_access_denied,
      outcome: :denied,
      reason: :unauthorized,
      # `occurred_at` is `:utc_datetime` — second precision, in the schema and
      # in the table — so a fixture instant is truncated rather than widened.
      occurred_at: truncated_now(),
      correlation_id: Ecto.UUID.generate()
    }

    %DeliverySecurityEvent{}
    |> DeliverySecurityEvent.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp truncated_now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp sorted_by_id(schema), do: schema |> Repo.all() |> Enum.sort_by(& &1.id)

  # Every row of every table, read straight out of the database rather than
  # through a schema, so a column no schema maps could not hide a change
  # either. Rows are sorted because table order is not guaranteed and this
  # asserts content, not storage order.
  defp database_snapshot do
    Map.new(comparable_tables(), fn table ->
      %Postgrex.Result{columns: columns, rows: rows} = Repo.query!(~s(SELECT * FROM "#{table}"))

      {table, {columns, Enum.sort(rows)}}
    end)
  end

  defp comparable_tables, do: Enum.reject(base_tables(), &(&1 in @mutable_tables))

  defp delivery_tables, do: Enum.filter(base_tables(), &String.starts_with?(&1, "delivery_"))

  defp base_tables do
    %Postgrex.Result{rows: rows} =
      Repo.query!("""
      SELECT table_name
      FROM information_schema.tables
      WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
      ORDER BY table_name
      """)

    List.flatten(rows)
  end

  defp raw_connection do
    {:ok, connection} = Postgrex.start_link(postgrex_options())
    Process.unlink(connection)
    on_exit(fn -> if Process.alive?(connection), do: GenServer.stop(connection) end)
    connection
  end

  defp postgrex_options do
    Repo.config()
    |> Keyword.take([:hostname, :port, :database, :username, :password])
    |> Keyword.put(:backoff_type, :stop)
  end
end
