defmodule SddOrchestrator.Privacy.Retention do
  @moduledoc """
  Storage-limitation enforcement for personal-data lifecycles.

  Deletes personal-data records once their approved retention window has passed:

    * GitHub authorization attempts — deleted 24 hours after creation (unusable
      after 10 minutes).
    * Project onboarding attempts — deleted 24 hours after abandonment (unconsumed
      and expired) or 24 hours after consumption, so redundant repository metadata
      does not linger once the project exists.
    * Application sessions — deleted 24 hours after expiry (idle or absolute) or
      revocation.
    * Passwordless attempts — unusable after their short authentication window
      and deleted after the configured post-expiry grace period.
    * Hosted sessions — deleted after their configured post-expiry grace period;
      explicit revocation deletes them immediately in the session context.
    * Restore import attempts — encrypted hosted and available device-local
      attempts are deleted no later than 24 hours after creation.
    * Project invitations — a pending invitation becomes terminal once its
      seven-day lifetime passes, which erases its credential immediately, and a
      terminal invitation is deleted no later than 30 days after it ended.
    * Departed participation — the link from a departed authorization to its
      stable hosted identity is erased no later than 30 days after departure.
      Active participation is never touched, and the departed row itself remains
      as governed project history.
    * Personal AI connections — an outstanding worker-local credential removal is
      retried first, so a connection the worker acknowledges in this pass starts
      its own terminal window now. An acknowledged connection's opaque
      control-plane reference is then deleted once its configured lifetime has
      passed. A connection with no acknowledgement is never deleted on a timer,
      because deleting the reference would not remove the worker's credential.
    * Model catalog and quota snapshots — deleted once the short configured
      lifetime written into each row has passed, and deleted outright for a
      connection that has reached a terminal revocation state or is already
      scheduled for deletion. Catalog and quota facts are personal data refreshed
      from the authenticated source, never a durable entitlement, so a withdrawn
      model or an old account fact must not outlive its stated lifetime. This
      sweep runs last and under its own advisory lock, so a connection that
      becomes terminal earlier in the same pass loses its evidence in that pass.
    * Pinned runtime sessions and their cost ledgers — a pinned configuration is
      the project's account of what a support conversation or working-agent run
      actually executed under, so it is kept for a bounded accountability window
      from the moment it was pinned and deleted with its ledger at that
      boundary. Removing the connection that funded the run detaches the opaque
      reference instead of destroying the account of the run, and a detached
      session serves a shorter window because no further execution can follow
      it. Pause state is never a deletion trigger: a paused session and its
      ledger stay intact and resumable for their whole window. This sweep runs
      after the connection delete and under its own advisory lock, so a session
      detached earlier in the same pass is judged as detached in that pass.

  Encrypted GitHub credentials and confirmed project metadata are kept while the
  account or project requires them and are removed by account erasure, not by time.
  Operational-security log and backup retention (30 and 35 days) are enforced by the
  deployment's log and backup infrastructure, recorded in the deployment privacy
  profile. These deletes are idempotent, so re-running the pruner is safe.
  """
  import Ecto.Query

  require Logger

  alias SddOrchestrator.Accounts.{ApplicationSession, GitHubAuthorizationAttempt}
  alias SddOrchestrator.Accounts.{HostedSession, MagicLinkAttempt}

  alias SddOrchestrator.AIRuntime.{
    AIRuntimeSession,
    ModelCatalogSnapshot,
    PersonalAIConnection,
    PersonalConnectionRevocations,
    QuotaSnapshot,
    RuntimeCostLedger
  }

  alias SddOrchestrator.Devices
  alias SddOrchestrator.IdentityLinking
  alias SddOrchestrator.Participation.Invitations
  alias SddOrchestrator.Participation.{ProjectInvitation, ProjectParticipant}
  alias SddOrchestrator.Portability.ImportAttempt
  alias SddOrchestrator.Projects.ProjectOnboardingAttempt
  alias SddOrchestrator.Repo

  @day 24 * 60 * 60

  # Terminal invitations and departed authorization-to-identity links are removed
  # within 30 days of reaching their approved lifecycle boundary.
  @participation_window 30 * @day

  # A stable, arbitrary key so every instance contends for the same lock. It is
  # deliberately distinct from the whole-pruner key and from the personal
  # connection revocation sweep's key, so a contended revocation sweep never
  # silently suppresses snapshot expiry and neither one waits on the other.
  @snapshot_advisory_lock_key 529_140_776

  # Distinct again from the whole-pruner, revocation, and snapshot keys, so the
  # runtime accountability sweep neither waits on nor silently suppresses them.
  @runtime_advisory_lock_key 384_612_907

  # A pinned configuration answers one question for the project that ran the
  # work: which model, at which reasoning effort, under which owner opt-ins and
  # which approved ceiling, produced this run or conversation. Ninety days is the
  # outer bound of that account. It already exceeds every other governed evidence
  # window in the deployment, including the 30-day operational log and 35-day
  # encrypted-backup lifetimes, so nothing downstream can still need it.
  @runtime_session_window 90 * @day

  # Once the connection that funded the run is gone, no further execution can
  # follow the pin and the owner has signalled that the processing is winding
  # down. What remains is the same accountability record every other terminal
  # lifecycle in this module keeps for 30 days.
  @detached_runtime_session_window 30 * @day

  @typedoc "Rows deleted by one catalog and quota snapshot sweep."
  @type snapshot_counts :: %{
          expired_model_catalog_snapshots: non_neg_integer(),
          expired_quota_snapshots: non_neg_integer()
        }

  @typedoc "Rows deleted by one runtime session and cost ledger sweep."
  @type runtime_counts :: %{
          expired_ai_runtime_sessions: non_neg_integer(),
          expired_runtime_cost_ledgers: non_neg_integer()
        }

  @doc "Runs every retention rule and returns the number of rows deleted per category."
  @spec prune_all(DateTime.t()) :: %{atom() => non_neg_integer()}
  def prune_all(now \\ DateTime.utc_now()) do
    now = DateTime.truncate(now, :second)

    %{
      authorization_attempts: prune_authorization_attempts(now),
      magic_link_attempts: prune_magic_link_attempts(now),
      onboarding_attempts: prune_onboarding_attempts(now),
      hosted_import_attempts: prune_hosted_import_attempts(now),
      device_import_attempts: prune_device_import_attempts(now),
      sessions: prune_sessions(now),
      hosted_sessions: prune_hosted_sessions(now),
      merge_records: IdentityLinking.prune_merge_records(now),
      expired_invitations: Invitations.expire_due(now),
      terminal_invitations: prune_terminal_invitations(now),
      departed_participant_links: prune_departed_participant_links(now),
      acknowledged_personal_ai_connections: reconcile_personal_ai_connections(now),
      revoked_personal_ai_connections: prune_revoked_personal_ai_connections(now)
    }
    |> Map.merge(snapshot_counts(now))
    |> Map.merge(runtime_counts(now))
  end

  @doc false
  @spec snapshot_advisory_lock_key() :: pos_integer()
  def snapshot_advisory_lock_key, do: @snapshot_advisory_lock_key

  @doc false
  @spec runtime_advisory_lock_key() :: pos_integer()
  def runtime_advisory_lock_key, do: @runtime_advisory_lock_key

  @doc """
  Deletes every pinned runtime session whose accountability window has passed.

  A session is due once its window has elapsed since it was pinned: the shorter
  detached window when its connection has been removed, the full window while it
  is still attached. Its ceiling ledger is deleted in the same statement pair
  rather than left to the cascade, so the reported counts describe what this
  pass actually removed. Returns `:locked` when another instance is sweeping; a
  contended sweep deletes nothing rather than duplicating the work. Both deletes
  are bounded statements in one transaction, so an interrupted pass leaves no
  ledger without its session and re-running converges.
  """
  @spec prune_ai_runtime_sessions(DateTime.t()) :: runtime_counts() | :locked
  def prune_ai_runtime_sessions(now \\ DateTime.utc_now()) do
    now = DateTime.truncate(now, :second)

    with_advisory_lock(@runtime_advisory_lock_key, "runtime accountability sweep", fn ->
      delete_due_runtime_records(due_runtime_session_ids(now))
    end)
  end

  @doc """
  Deletes every catalog and quota snapshot that may no longer be presented.

  A snapshot is unusable once the short lifetime stored on the row has passed,
  or once its connection is terminal or already scheduled for deletion. Returns
  the deleted count per table, or `:locked` when another instance is sweeping;
  a contended sweep deletes nothing rather than duplicating the work. Both
  deletes are single bounded statements, so an interrupted pass leaves no
  partial state and re-running converges without touching current evidence.
  """
  @spec prune_ai_runtime_snapshots(DateTime.t()) :: snapshot_counts() | :locked
  def prune_ai_runtime_snapshots(now \\ DateTime.utc_now()) do
    now = DateTime.truncate(now, :second)

    with_snapshot_lock(fn ->
      %{
        expired_model_catalog_snapshots: delete_unusable_snapshots(ModelCatalogSnapshot, now),
        expired_quota_snapshots: delete_unusable_snapshots(QuotaSnapshot, now)
      }
    end)
  end

  # The sweep runs after reconciliation and after the terminal-reference delete,
  # so a connection that becomes terminal in this pass loses its evidence now and
  # the reported counts never double-count a row the connection cascade removed.
  defp snapshot_counts(now) do
    case prune_ai_runtime_snapshots(now) do
      :locked -> %{expired_model_catalog_snapshots: 0, expired_quota_snapshots: 0}
      counts -> counts
    end
  end

  defp delete_unusable_snapshots(schema, now) do
    {count, _} =
      Repo.delete_all(
        from snapshot in schema,
          where:
            snapshot.expires_at <= ^now or
              snapshot.connection_id in subquery(terminal_connection_ids())
      )

    count
  end

  # Terminal means the worker confirmed the credential removal, or the reference
  # is already counting down to deletion. Either way the connection can fund no
  # further work, so its catalog and quota evidence has no remaining purpose.
  defp terminal_connection_ids do
    from connection in PersonalAIConnection,
      where:
        connection.revocation_state == "acknowledged" or
          not is_nil(connection.deletion_scheduled_at),
      select: connection.id
  end

  # The runtime sweep runs after the terminal-connection delete, so a session
  # this pass detached is judged as detached now rather than one pass later.
  defp runtime_counts(now) do
    case prune_ai_runtime_sessions(now) do
      :locked -> %{expired_ai_runtime_sessions: 0, expired_runtime_cost_ledgers: 0}
      counts -> counts
    end
  end

  defp due_runtime_session_ids(now) do
    attached_cutoff = DateTime.add(now, -@runtime_session_window, :second)
    detached_cutoff = DateTime.add(now, -@detached_runtime_session_window, :second)

    from session in AIRuntimeSession,
      where:
        session.pinned_at <= ^attached_cutoff or
          (is_nil(session.connection_id) and session.pinned_at <= ^detached_cutoff),
      select: session.id
  end

  # The ledger has no purpose without the session whose ceiling it holds, so it
  # is deleted first and in the same transaction; the cascade would remove it
  # either way but could not report what this pass removed.
  defp delete_due_runtime_records(due) do
    {:ok, counts} =
      Repo.transaction(fn ->
        {ledgers, _} =
          Repo.delete_all(
            from ledger in RuntimeCostLedger, where: ledger.session_id in subquery(due)
          )

        {sessions, _} =
          Repo.delete_all(from session in AIRuntimeSession, where: session.id in subquery(due))

        %{expired_ai_runtime_sessions: sessions, expired_runtime_cost_ledgers: ledgers}
      end)

    counts
  end

  defp with_snapshot_lock(sweep) do
    with_advisory_lock(
      @snapshot_advisory_lock_key,
      "catalog and quota snapshot sweep",
      sweep
    )
  end

  # The lock is session-scoped, so it must be taken and released on the same
  # checked-out connection.
  defp with_advisory_lock(key, sweep_name, sweep) do
    Repo.checkout(fn ->
      case Repo.query("SELECT pg_try_advisory_lock($1)", [key]) do
        {:ok, %{rows: [[true]]}} ->
          try do
            sweep.()
          after
            Repo.query("SELECT pg_advisory_unlock($1)", [key])
          end

        {:ok, _not_acquired} ->
          :locked

        {:error, reason} ->
          Logger.warning(sweep_name <> " could not acquire advisory lock: " <> inspect(reason))

          :locked
      end
    end)
  end

  # Reconciliation runs before the delete for the same reason invitation expiry
  # does: a connection that becomes terminal in this pass starts its own
  # retention window now rather than being deleted the instant it completes.
  # A worker that cannot be reached is an environment fact, not a retention
  # failure, so it never stops the rest of the pass.
  defp reconcile_personal_ai_connections(now) do
    case PersonalConnectionRevocations.reconcile(now) do
      {:ok, %{acknowledged: acknowledged}} -> acknowledged
      :locked -> 0
    end
  catch
    :exit, _unavailable_worker_transport -> 0
  end

  defp prune_revoked_personal_ai_connections(now) do
    {count, _} =
      Repo.delete_all(
        from connection in PersonalAIConnection,
          where:
            not is_nil(connection.deletion_scheduled_at) and
              connection.deletion_scheduled_at <= ^now
      )

    count
  end

  # A terminal invitation already lost its credential at the transition itself, so
  # what remains is the invited address and its comparison digest. Thirty days
  # after the invitation ended, that address is no longer needed for replay,
  # dispute, or support evidence, and the row is deleted. Expiry runs first, so an
  # invitation that becomes terminal in this same pass starts its own 30 days now.
  defp prune_terminal_invitations(now) do
    cutoff = DateTime.add(now, -@participation_window, :second)

    {count, _} =
      Repo.delete_all(
        from invitation in ProjectInvitation,
          where: invitation.status != "pending" and invitation.terminal_at <= ^cutoff
      )

    count
  end

  # Departure ends authorization immediately; the row stays as governed project
  # history. Thirty days later the link from that history to the person's stable
  # hosted identity is erased. Active participation is retained only while active
  # and is never selected here.
  defp prune_departed_participant_links(now) do
    cutoff = DateTime.add(now, -@participation_window, :second)

    {count, _} =
      Repo.update_all(
        from(participant in ProjectParticipant,
          where:
            participant.state == "departed" and participant.departed_at <= ^cutoff and
              not is_nil(participant.hosted_identity_id)
        ),
        set: [hosted_identity_id: nil, updated_at: now]
      )

    count
  end

  defp prune_authorization_attempts(now) do
    cutoff = DateTime.add(now, -@day, :second)

    {count, _} =
      Repo.delete_all(from a in GitHubAuthorizationAttempt, where: a.inserted_at < ^cutoff)

    count
  end

  defp prune_magic_link_attempts(now) do
    cutoff =
      DateTime.add(
        now,
        -retention_seconds(:magic_link_attempt_grace_seconds),
        :second
      )

    {count, _} =
      Repo.delete_all(
        from attempt in MagicLinkAttempt,
          where:
            attempt.expires_at < ^cutoff or attempt.consumed_at < ^cutoff or
              attempt.invalidated_at < ^cutoff
      )

    count
  end

  defp prune_onboarding_attempts(now) do
    day_ago = DateTime.add(now, -@day, :second)

    {count, _} =
      Repo.delete_all(
        from a in ProjectOnboardingAttempt,
          where:
            (is_nil(a.consumed_at) and a.expires_at < ^now) or
              (not is_nil(a.consumed_at) and a.consumed_at < ^day_ago)
      )

    count
  end

  defp prune_hosted_import_attempts(now) do
    cutoff = DateTime.add(now, -@day, :second)

    {count, _} =
      Repo.delete_all(
        from attempt in ImportAttempt,
          where: attempt.inserted_at <= ^cutoff or attempt.expires_at <= ^now
      )

    count
  end

  defp prune_device_import_attempts(now) do
    case Devices.prune_import_attempts(now) do
      {:ok, count} when is_integer(count) and count >= 0 -> count
      _unavailable_or_invalid -> 0
    end
  catch
    :exit, _unavailable_store -> 0
  end

  defp prune_sessions(now) do
    day_ago = DateTime.add(now, -@day, :second)

    {count, _} =
      Repo.delete_all(
        from s in ApplicationSession,
          where:
            s.revoked_at < ^day_ago or s.absolute_expires_at < ^day_ago or
              s.idle_expires_at < ^day_ago
      )

    count
  end

  defp prune_hosted_sessions(now) do
    cutoff =
      DateTime.add(
        now,
        -retention_seconds(:hosted_session_grace_seconds),
        :second
      )

    {count, _} =
      Repo.delete_all(from session in HostedSession, where: session.expires_at < ^cutoff)

    count
  end

  defp retention_seconds(key) do
    :sdd_orchestrator
    |> Application.fetch_env!(:passwordless_retention)
    |> Keyword.fetch!(key)
  end
end
