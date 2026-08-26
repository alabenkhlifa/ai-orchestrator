defmodule SddOrchestrator.Privacy.DeliveryRetentionRunnerTest do
  @moduledoc """
  specs/19 Task 3 proof: retention runs rule by rule under per-rule advisory
  locks, isolates a rule that does not complete, and records the outcome of
  each rule's last pass durably enough to survive a restart — in a record that
  is structurally incapable of holding what the rules delete.
  """

  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Accounts.{GitHubAuthorizationAttempt, HostedSession}
  alias SddOrchestrator.Devices.DeviceStore.Local
  alias SddOrchestrator.HostedAccessFixtures
  alias SddOrchestrator.Privacy.{Retention, RetentionPruner, RetentionRuleOutcome}

  @day 24 * 60 * 60
  @window 30 * @day

  # A misconfiguration whose exception message names exactly the kind of thing
  # the retention rules exist to delete. `prune_hosted_sessions/1` reads its
  # window through `Keyword.fetch!/2`, so removing that one key raises a
  # `KeyError` carrying the whole replacement keyword list in its message —
  # a genuine failure inside one rule, injected without touching any rule's
  # own code, eligibility, instants, or counts.
  @leaked_email "leaked-participant-8f21@example.com"
  @leaked_project_id "0e4a9d3c-11b2-4b77-9d13-6a5f7c2e18aa"

  @device_rules [
    :device_import_attempts,
    :expired_device_delivery_commands,
    :expired_device_delivery_checkpoints,
    :expired_device_delivery_artifacts,
    :expired_device_delivery_previews,
    :device_project_assistant_conversations
  ]

  setup do
    path = store_path()
    on_exit(fn -> File.rm_rf!(Path.dirname(path)) end)
    start_supervised!({Local, path: path})

    configured = Application.fetch_env!(:sdd_orchestrator, :passwordless_retention)

    on_exit(fn ->
      Application.put_env(:sdd_orchestrator, :passwordless_retention, configured)
    end)

    %{store_path: path, passwordless_retention: configured}
  end

  describe "the outcome record's own boundary" do
    test "declares no column that could carry what the rules delete" do
      fields = RetentionRuleOutcome.__schema__(:fields)

      assert fields == [
               :id,
               :rule,
               :state,
               :failure_class,
               :attempt_count,
               :last_attempted_at,
               :succeeded_at,
               :correlation_id,
               :inserted_at,
               :updated_at
             ]

      refute Enum.any?(fields, fn field ->
               field
               |> Atom.to_string()
               |> String.match?(
                 ~r/project|participant|account|workspace|device|worker|feature|artifact|evidence|invitation|session_id|email|address|token|digest|path|message|detail|payload|query|trace|stack|reason|deleted|removed/
               )
             end)

      assert RetentionRuleOutcome.__schema__(:associations) == []

      assert RetentionRuleOutcome.states() == [:succeeded, :failed, :retry_pending]

      assert RetentionRuleOutcome.failure_classes() == [
               :store_unavailable,
               :database_unavailable,
               :constraint_violation,
               :unexpected_error
             ]

      assert Enum.sort(Retention.rule_names()) == RetentionRuleOutcome.rules()
    end

    test "keeps nothing but the coarse class when a rule fails carrying a rich error" do
      break_hosted_session_window()

      Retention.prune_all(now())

      recorded = outcome(:hosted_sessions)
      assert recorded.state == :failed
      assert recorded.failure_class == :unexpected_error

      # Every column of the stored row, read straight out of the database
      # rather than through the schema, so a column the schema does not map
      # could not hide the leak either.
      %Postgrex.Result{rows: [stored]} =
        Repo.query!("SELECT * FROM retention_rule_outcomes WHERE rule = 'hosted_sessions'")

      serialized = inspect(stored)

      refute String.contains?(serialized, @leaked_email)
      refute String.contains?(serialized, @leaked_project_id)
      refute String.contains?(serialized, "hosted_session_grace_seconds")
      refute String.contains?(serialized, "KeyError")

      assert recorded.correlation_id != @leaked_project_id
      assert {:ok, _fresh} = Ecto.UUID.cast(recorded.correlation_id)
    end
  end

  describe "per-rule locking" do
    test "assigns every rule its own key, pairwise distinct and reserved" do
      keys = Enum.map(Retention.rule_names(), &Retention.rule_advisory_lock_key/1)

      assert length(keys) == length(Retention.rule_names())
      assert Enum.uniq(keys) == keys
      assert Enum.all?(keys, &(is_integer(&1) and &1 > 0))

      refute RetentionPruner.advisory_lock_key() in keys

      legacy = [
        Retention.snapshot_advisory_lock_key(),
        Retention.runtime_advisory_lock_key(),
        Retention.observation_advisory_lock_key(),
        Retention.project_assistant_advisory_lock_key()
      ]

      for key <- keys -- legacy do
        assert key in Retention.rule_advisory_lock_band()
      end

      for key <- legacy do
        refute key in Retention.rule_advisory_lock_band()
      end
    end

    test "a contended rule reports zero, leaves its record alone, and never blocks another" do
      pass_now = now()
      Retention.prune_all(pass_now)
      before = outcome(:authorization_attempts)

      attempt = due_authorization_attempt(pass_now)
      connection = raw_connection()
      key = Retention.rule_advisory_lock_key(:authorization_attempts)

      assert %Postgrex.Result{rows: [[:void]]} =
               Postgrex.query!(connection, "SELECT pg_advisory_lock($1)", [key])

      counts = Retention.prune_all(pass_now)

      assert counts.authorization_attempts == 0
      assert Repo.get(GitHubAuthorizationAttempt, attempt.id)

      contended = outcome(:authorization_attempts)
      assert contended.attempt_count == before.attempt_count
      assert contended.correlation_id == before.correlation_id

      # The rule that follows it in the same pass ran regardless.
      assert outcome(:magic_link_attempts).attempt_count == before.attempt_count + 1

      assert %Postgrex.Result{rows: [[true]]} =
               Postgrex.query!(connection, "SELECT pg_advisory_unlock($1)", [key])

      assert %{authorization_attempts: 1} = Retention.prune_all(pass_now)
      refute Repo.get(GitHubAuthorizationAttempt, attempt.id)
      assert outcome(:authorization_attempts).attempt_count == before.attempt_count + 1
    end
  end

  describe "isolation" do
    test "a rule that raises does not abort the pass and every other rule still runs" do
      pass_now = now()
      attempt = due_authorization_attempt(pass_now)
      break_hosted_session_window()

      counts = Retention.prune_all(pass_now)

      assert counts.authorization_attempts == 1
      assert counts.hosted_sessions == 0
      refute Repo.get(GitHubAuthorizationAttempt, attempt.id)

      for category <- Map.keys(counts) do
        assert is_integer(counts[category])
      end

      assert outcome(:hosted_sessions).state == :failed

      for name <- Retention.rule_names() -- [:hosted_sessions] do
        assert %{state: :succeeded, failure_class: nil} = outcome(name)
      end
    end

    test "a second pass with nothing due records success with zero work and does not double-count" do
      pass_now = now()
      attempt = due_authorization_attempt(pass_now)

      assert %{authorization_attempts: 1} = Retention.prune_all(pass_now)
      first = outcome(:authorization_attempts)
      assert first.state == :succeeded
      assert first.attempt_count == 1

      assert %{authorization_attempts: 0} = Retention.prune_all(pass_now)
      second = outcome(:authorization_attempts)

      assert second.state == :succeeded
      assert second.attempt_count == 2
      assert second.id == first.id
      assert second.correlation_id != first.correlation_id
      refute Repo.get(GitHubAuthorizationAttempt, attempt.id)

      assert Repo.aggregate(
               from(o in RetentionRuleOutcome, where: o.rule == ^:authorization_attempts),
               :count
             ) == 1
    end

    test "the attempt count advances on every failing pass" do
      pass_now = now()
      break_hosted_session_window()

      Retention.prune_all(pass_now)
      assert %{state: :failed, attempt_count: 1} = outcome(:hosted_sessions)

      Retention.prune_all(pass_now)
      assert %{state: :failed, attempt_count: 2, succeeded_at: nil} = outcome(:hosted_sessions)
    end
  end

  describe "restart discovery and retry" do
    test "a rule left failed is discoverable after a restart and retried on the next pass" do
      pass_now = now()
      session = due_hosted_session(pass_now)
      break_hosted_session_window()

      first_pid = start_supervised!({RetentionPruner, interval: :timer.hours(1)})

      assert %{hosted_sessions: 0} = RetentionPruner.prune_with_lock(pass_now)
      assert %{state: :failed, attempt_count: 1} = outcome(:hosted_sessions)
      assert Repo.get(HostedSession, session.id)

      Process.exit(first_pid, :kill)

      assert_eventually(fn ->
        case Process.whereis(RetentionPruner) do
          pid when is_pid(pid) -> pid != first_pid
          _not_restarted -> false
        end
      end)

      # Discoverable from the repository alone, with no handoff from the pass
      # that failed: the next pass finds it and retries it now rather than
      # waiting for the rule's next natural schedule.
      assert :hosted_sessions in incomplete_rule_names()

      restore_hosted_session_window()

      assert %{hosted_sessions: 1} = RetentionPruner.prune_with_lock(pass_now)

      retried = outcome(:hosted_sessions)
      assert retried.state == :succeeded
      assert retried.failure_class == nil
      assert retried.attempt_count == 2
      assert DateTime.compare(retried.succeeded_at, pass_now) == :eq
      refute Repo.get(HostedSession, session.id)
      refute :hosted_sessions in incomplete_rule_names()
    end

    test "a retried pass never restores what an earlier pass deleted" do
      pass_now = now()
      session = due_hosted_session(pass_now)

      assert %{hosted_sessions: 1} = Retention.prune_all(pass_now)
      refute Repo.get(HostedSession, session.id)

      break_hosted_session_window()
      assert %{hosted_sessions: 0} = Retention.prune_all(pass_now)
      assert %{state: :failed} = outcome(:hosted_sessions)
      refute Repo.get(HostedSession, session.id)

      restore_hosted_session_window()
      assert %{hosted_sessions: 0} = Retention.prune_all(pass_now)
      assert %{state: :succeeded, attempt_count: 3} = outcome(:hosted_sessions)
      refute Repo.get(HostedSession, session.id)
    end
  end

  describe "reconciliation across authorities" do
    test "an unreachable device store pauses only its own rules and is recorded as such", %{
      store_path: path
    } do
      pass_now = now()
      attempt = due_authorization_attempt(pass_now)

      :ok = stop_supervised(Local)

      counts = Retention.prune_all(pass_now)

      # The hosted half of the very same pass completed normally.
      assert counts.authorization_attempts == 1
      refute Repo.get(GitHubAuthorizationAttempt, attempt.id)
      assert %{state: :succeeded, failure_class: nil} = outcome(:authorization_attempts)

      for name <- @device_rules do
        assert %{state: :retry_pending, failure_class: :store_unavailable} = outcome(name)
      end

      assert counts.device_import_attempts == 0
      assert counts.expired_device_delivery_commands == 0
      assert counts.expired_device_delivery_previews == 0
      assert Enum.all?(@device_rules, &(&1 in incomplete_rule_names()))

      # Retried later, once the authority can be asked again.
      start_supervised!({Local, path: path})
      Retention.prune_all(pass_now)

      for name <- @device_rules do
        assert %{state: :succeeded, failure_class: nil, attempt_count: 2} = outcome(name)
      end
    end
  end

  describe "the record prunes itself" do
    test "releases its own stale record without erasing the pass it is running in" do
      pass_now = now()

      assert %{expired_retention_rule_outcomes: 0} = Retention.prune_all(pass_now)
      assert %{state: :succeeded} = outcome(:retention_rule_outcomes)

      # Both rows are pushed past the 30-day boundary. Only one of them can
      # still be stale when the sweep runs: a rule that still exists is
      # rewritten with a fresh success earlier in the same pass, while the
      # sweep's own row is written only after its body returns.
      backdate([:retention_rule_outcomes, :authorization_attempts], pass_now)

      assert %{expired_retention_rule_outcomes: 1} = Retention.prune_all(pass_now)

      own = outcome(:retention_rule_outcomes)
      assert own.state == :succeeded
      assert DateTime.compare(own.succeeded_at, pass_now) == :eq

      refreshed = outcome(:authorization_attempts)
      assert refreshed.state == :succeeded
      assert DateTime.compare(refreshed.succeeded_at, pass_now) == :eq
    end

    test "never releases a rule that is still failing, however old its last success" do
      pass_now = now()

      Retention.prune_all(pass_now)
      break_hosted_session_window()
      Retention.prune_all(pass_now)

      assert %{state: :failed} = outcome(:hosted_sessions)

      Repo.update_all(
        from(o in RetentionRuleOutcome, where: o.rule == ^:hosted_sessions),
        set: [succeeded_at: DateTime.add(pass_now, -@window - 1, :second)]
      )

      assert %{expired_retention_rule_outcomes: 0} = Retention.prune_all(pass_now)
      assert %{state: :failed} = outcome(:hosted_sessions)
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp outcome(name), do: Repo.get_by!(RetentionRuleOutcome, rule: name)

  defp incomplete_rule_names do
    Repo.all(from o in RetentionRuleOutcome, where: o.state != ^:succeeded, select: o.rule)
  end

  defp backdate(names, pass_now) do
    stale = DateTime.add(pass_now, -@window - 1, :second)

    Repo.update_all(
      from(o in RetentionRuleOutcome, where: o.rule in ^names),
      set: [succeeded_at: stale, last_attempted_at: stale]
    )
  end

  defp due_authorization_attempt(pass_now) do
    attempt =
      Repo.insert!(%GitHubAuthorizationAttempt{
        state_digest: "state-#{System.unique_integer([:positive])}",
        browser_nonce_digest: "nonce",
        pkce_verifier: "verifier",
        expires_at: DateTime.add(pass_now, 600, :second)
      })

    Repo.update_all(
      from(a in GitHubAuthorizationAttempt, where: a.id == ^attempt.id),
      set: [inserted_at: DateTime.add(pass_now, -@day - 3600, :second)]
    )

    attempt
  end

  defp due_hosted_session(pass_now) do
    session = HostedAccessFixtures.verified_hosted_session_fixture().session

    Repo.update_all(
      from(s in HostedSession, where: s.id == ^session.id),
      set: [expires_at: DateTime.add(pass_now, -@day - 3600, :second)]
    )

    session
  end

  defp break_hosted_session_window do
    Application.put_env(:sdd_orchestrator, :passwordless_retention,
      magic_link_attempt_grace_seconds: @day,
      participant_email: @leaked_email,
      project_id: @leaked_project_id
    )
  end

  defp restore_hosted_session_window do
    Application.put_env(:sdd_orchestrator, :passwordless_retention,
      magic_link_attempt_grace_seconds: @day,
      hosted_session_grace_seconds: @day
    )
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

  defp store_path do
    directory =
      Path.join(
        System.tmp_dir!(),
        "sdd_retention_runner_#{System.unique_integer([:positive])}"
      )

    Path.join(directory, "store.dets")
  end

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
end
