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
    * Participation revocation handoffs — former account and hosted-identity
      routing links are erased no later than 30 days after the handoff occurred.
      The stable handoff and its acknowledgement state remain intact.
    * Participation email-delivery diagnostics — a finalized (`"sent"` or
      `"failed"`) `ParticipationEmailDelivery` row is deleted 30 days after its
      authoritative attempt or completion time (`delivered_at` when present,
      otherwise `attempted_at`). A `"pending"` row is never selected: it still
      represents retry state the delivery workflow may need, not evidence whose
      short diagnostic purpose has ended. The invitation, participant, profile,
      revocation, and account rows this diagnostic references are never
      touched by this delete.
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
    * Agent runtime observations — the operational trail of one run is deleted
      30 days after it was observed, which is shorter than the accountability
      window its own session and ledger serve. Operating and pausing work
      safely, and answering a near-term question about what a run was doing,
      are near-term purposes; the account of what the run executed under and
      what it cost is held elsewhere and outlives the trail. This sweep runs
      last and under its own advisory lock, so it never recounts an observation
      the session cascade already removed earlier in the same pass.
    * Repository-initialization plans and runs — a plan abandoned with no run
      ever started is deleted 24 hours after its last update, the same
      unconsumed-abandonment idiom the onboarding-attempt rule above uses. A
      run left `"failed"` or `"canceled"` is deleted 24 hours after it
      finished (or was last updated, if it never recorded a finish time) once
      no `RepositoryInitializationResult` exists for it, and its
      now-unreferenced plan is deleted with it. A run still `"pending"` or
      `"running"` is an in-flight build and is never touched here. Once a
      `RepositoryInitializationResult` exists, its plan and run are never
      deleted by this timer, regardless of `onboarding_handoff_state` — a
      result is the project's own confirmed birth record and follows the same
      rule as confirmed project metadata below.
    * Slice 07 guided-delivery notifications — a `delivery.`-namespace
      `AccountNotification` row is deleted 90 days after its own
      `occurred_at`, whether it was read or left unread; read state is never
      consulted. The notification is only a projection presenting a delivery
      event, so removing it changes no feature, run, review, assignment, or
      participation state. Slice 08's `participation.`-namespace rows on the
      same schema are a different feature's data and are never selected here.
    * Participation account notifications — a `participation.`-namespace
      `AccountNotification` row is deleted 90 days after its own
      `occurred_at`, whether it was read or left unread; read state is never
      consulted. The row is only a projection of an invitation, join,
      decline, removal, or departure event that already happened elsewhere,
      so removing it changes no invitation, participant, profile, or
      revocation state, and no current project authorization. The
      `delivery.`-namespace rows above are a different feature's data and are
      never selected here, and a row outside the approved notification
      vocabulary is never selected either.
    * Participation operational-security events — a fixed, minimized
      `ParticipationSecurityEvent` row (specs/27 Task 3, AC-03) is deleted 30
      days after its own `occurred_at` through
      `SddOrchestrator.Privacy.ParticipationSecurityLog`'s retention-capable
      local sink. The event carries only an allowlisted event type, coarse
      outcome, fixed reason classification when required, UTC occurrence
      time, and a fresh non-secret correlation identifier; it is its own
      locally provable 30-day window, independent of the deployment-enforced
      operational-security log ceiling `AIRuntime.SecurityLog` documents.
      Emitting or pruning a security event never reads or changes any
      invitation, participant, profile, revocation, or account row.
    * Guided-delivery temporary execution data — an inactive `RunCommand` is
      deleted 30 days after its purpose ended (`acknowledged_at` when present,
      otherwise `updated_at`), and a resolved `BlockingQuestion` is deleted 30
      days after the resolution that bumped its `updated_at`. Both rows carry
      only execution mechanics: the command's operation, manifest digest,
      claim, result, and failure code, and the question's opaque checkpoint,
      branch, and worker-local workspace path. Neither is selected while its
      own run is still active — a command or question belonging to a run that
      has not reached `"failed"`, `"canceled"`, or `"completed"` is current
      recovery material whatever its age, because that run can still be
      resumed, retried, or reconciled from it. The participant-visible
      question and its answer are not deleted here: they are duplicated into
      `activity_entries` as `"question_asked"` and `"question_answered"`,
      which is the retained authoritative history and is governed by its own
      lifecycle rather than by this window. A device-authoritative project gets
      the same window and the same run-still-active exclusion, decided inside
      the device authority through `SddOrchestrator.Devices`' delivery API and
      applied as a tombstone put rather than a key delete (the delivery seam
      applies puts and nothing else). Nothing about a device project is read
      from or written to the hosted store to make that decision, and an
      unreachable worker pauses only this rule.
    * Superseded guided-delivery evidence artifacts — the stored *bytes* a
      superseded `Evidence` row names are removed from the project's artifact
      store 30 days after that row was superseded. Nothing about the row
      itself changes: `superseded_by_id`, `artifact_ref`, `digest`, and
      `recorded_at` are provenance, the database refuses to rewrite them
      (`evidence_reject_rewrite`), and this rule never issues a delete or an
      update against `evidence` at all. What is released is only the screenshot
      or log the superseded result captured, which no longer proves anything
      once a later result replaced it; the row keeps naming a reference whose
      bytes are gone, and `ArtifactStore.fetch/3` answers for it exactly as it
      answers for content that was never stored. The supersession instant is
      the *replacement* row's `inserted_at`: `evidence` deliberately has no
      `updated_at` and no `superseded_at`, and the replacement is inserted in
      the same atomic commit as the supersession link
      (`SddOrchestrator.Delivery.EvidenceIngestion`), so a server-written
      timestamp no worker can backdate already records exactly when the older
      result stopped being current. Artifacts are digest-addressed, so one
      stored object can be named by several rows; a reference is released only
      when *no* evidence row of the same project still needs it — a current
      row, or one superseded more recently than the window — which is what
      keeps accepted evidence's bytes from being destroyed by an unrelated
      row's expiry. A device-authoritative project gets the same window, the
      same never-rewrite-the-record contract, and the same digest-safety check,
      resolved entirely inside the device authority through
      `SddOrchestrator.Devices`' delivery API and applied through the device
      artifact adapter's own tombstone. Its supersession instant is the
      replacement record's `recorded_at` rather than an `inserted_at`:
      `Evidence.to_value/1` emits no Ecto timestamp at all, so the
      server-written instant the hosted half measures does not survive device
      serialization, and on a device the worker is the authority for when its
      own result happened. Nothing about a device project is read from or
      written to the hosted store to make that decision, and an unreachable
      worker pauses only this rule.
    * Terminal preview deployments — a `PreviewDeployment` row is deleted 30
      days after the preview it describes stopped being useful. Terminal is
      exactly "not `PreviewDeployment.open_statuses/0`", so all four of the
      statuses a preview can stop in are governed and each is measured by the
      instant that actually ended its purpose rather than by one shared
      approximation. `"expired"` uses `expires_at`, the moment it stopped
      being reachable, falling back to `updated_at` for a row a provider
      called expired without ever stating a time — the same
      authoritative-instant-or-last-write idiom the command rule above uses,
      available here because `preview_deployments` does carry `timestamps()`,
      which `evidence` deliberately does not. `"superseded"` uses the
      *replacement* row's `inserted_at`, written in the same atomic commit as
      the supersession link (`SddOrchestrator.Delivery.Previews`) and frozen
      afterwards by the `preview_deployments_binding_frozen` trigger, exactly
      as the evidence rule above reasons and for the same reason: the
      superseded row's own `expires_at` says when its preview stopped being
      reachable, which is a different question from when a later attempt
      replaced it. `"timed_out"` uses `timeout_at`, the deadline the request
      policy set and the one `Previews` compares against to declare the
      timeout, so the row is measured from when the preview stopped being
      useful rather than from when that was noticed. `"failed"` uses
      `updated_at` alone: a provider refusal records no expiry and no
      deadline of its own, so the failure write is the only instant the row
      has and none is invented for it. A `"pending"` or `"ready"` deployment
      is never selected whatever its age — it is still the preview a reviewer
      opens. Age alone is never enough either: a row is released only once
      `cleanup_state` is `"done"`, the one value that means the provider
      confirmed the deployment itself was torn down. Deleting a row whose
      remote release is still owed (`"none"`), recorded but unconfirmed
      (`"requested"`), or refused (`"failed"`) would leave a preview serving
      the project's content at a provider nothing can name any more, which is
      a worse outcome than retaining the row, and that guard is not
      status-specific. The feature, run, attempt, activity history, and
      evidence the preview belonged to are never touched. A device-authoritative
      project gets the same window, the same terminal-status boundary, and the
      same confirmed-remote guard, resolved entirely inside the device authority
      through `SddOrchestrator.Devices`' delivery API and applied as a tombstone
      put rather than a key delete. What differs is what it can be dated by:
      `PreviewDeployment.to_value/1` emits no `inserted_at` and no
      `updated_at`, so `"expired"` is measured by `expires_at` alone with no
      last-write fallback, `"superseded"` by the replacement record's
      `requested_at` — written in the same atomic commit as the supersession
      link, which is the device-visible instant of the write the hosted half
      measures as `inserted_at` — and `"timed_out"` by `timeout_at`, which
      every decodable record carries. A `"failed"` preview, and an `"expired"`
      one whose provider never stated an expiry, carry no instant of their own
      across that seam and are retained rather than released against an instant
      that answers a different question. A releasable record that a retained
      one still names through `superseded_by_id` is held back until that one is
      releasable too, so the sweep never leaves a retained record naming a
      replacement that is gone. Nothing about a device project is read from or
      written to the hosted store to make that decision, and an unreachable
      worker pauses only this rule.
    * Spent attempt-lease claims — the `lease_owner` and `lease_expires_at` a
      terminal `RunAttempt` is still carrying are cleared 30 days after it
      finished. Terminal is exactly `RunAttempt.terminal_states/0`, and
      "finished" is `updated_at`: an attempt has no `finished_at` column, and
      reaching a terminal state is by construction the last write it can take,
      because every transition out of one is illegal. This is an update, never
      a delete — the attempt, its outcome, its ordering, and its fence token
      are participant-visible history owned by the delivery lifecycle, and the
      row is removed with its run and not by time. Only a claim actually still
      held is selected, so the reported count describes work this pass did and
      a repeat pass reports nothing. Both lease columns are cleared in the same
      statement because `run_attempts_lease_pairing` requires them to be null
      or non-null together; clearing one alone would abort the whole pass, and
      the constraint exists because an owner without an expiry lets a stale
      claim look current forever. `fence_token` is deliberately untouched: it
      is the ordering that keeps a superseded worker's late events rejected,
      it is `null: false` and must stay positive and unique within its run, and
      it expires with the attempt row rather than on this window.

  Encrypted GitHub credentials and confirmed project metadata are kept while the
  account or project requires them and are removed by account erasure, not by time.
  A completed repository-initialization result, and the plan and run it
  completed, follow this identical rule for the identical reason: they are the
  project's own confirmed birth record and are removed by account erasure
  (`Rights.erase_account/2`), not by time. Every other operational-security
  log and backup retention (30 and 35 days) is enforced by the deployment's
  log and backup infrastructure, recorded in the deployment privacy profile —
  participation operational-security events are the one category this module
  deletes locally, per the paragraph above. These deletes are idempotent, so
  re-running the pruner is safe.
  """
  import Ecto.Query

  require Logger

  alias SddOrchestrator.Accounts.{ApplicationSession, GitHubAuthorizationAttempt}

  alias SddOrchestrator.Accounts.{
    DeviceWorkspace,
    HostedIdentity,
    HostedSession,
    MagicLinkAttempt,
    PersonalWorkspace
  }

  alias SddOrchestrator.AIRuntime.{
    AgentRuntimeObservation,
    AIRuntimeSession,
    ModelCatalogSnapshot,
    PersonalAIConnection,
    PersonalConnectionRevocations,
    QuotaSnapshot,
    RuntimeCostLedger
  }

  alias SddOrchestrator.Delivery.{
    AgentRun,
    ArtifactStore,
    BlockingQuestion,
    Evidence,
    PreviewDeployment,
    RunAttempt,
    RunCommand
  }

  alias SddOrchestrator.Devices
  alias SddOrchestrator.IdentityLinking
  alias SddOrchestrator.Notifications.AccountNotification
  alias SddOrchestrator.Participation.Invitations

  alias SddOrchestrator.Participation.{
    ParticipationEmailDelivery,
    ParticipationRevocation,
    ProjectInvitation,
    ProjectParticipant
  }

  alias SddOrchestrator.Portability.ImportAttempt

  alias SddOrchestrator.ProjectAssistant.{
    AssistantBoundaryConfirmation,
    DeviceProjectAssistantConversation,
    ProjectAssistantConversation
  }

  alias SddOrchestrator.Projects.{Project, ProjectOnboardingAttempt}
  alias SddOrchestrator.Repo
  alias SddOrchestrator.RepositoryInitialization.{Plan, Result, Run}

  @day 24 * 60 * 60

  # Terminal invitations and departed authorization-to-identity links are removed
  # within 30 days of reaching their approved lifecycle boundary.
  @participation_window 30 * @day

  # A finalized participation email-delivery diagnostic serves a short
  # operational purpose (explaining and, while pending, retrying delivery),
  # not a durable record. It is removed 30 days after its own authoritative
  # attempt or completion time, its own named window even though the value
  # matches `@participation_window` above.
  @participation_email_delivery_window 30 * @day

  # A Slice 07 guided-delivery notification is a presentation projection of an
  # event that already happened; the event's own workflow, run, review,
  # assignment, and participation state live elsewhere and are unaffected by
  # this delete. Ninety days after it occurred, whether read or unread, the
  # projection itself is removed.
  @delivery_notification_window 90 * @day

  # A participation account notification (invitation, join, decline, removal,
  # or departure) is the same kind of presentation projection as the Slice 07
  # guided-delivery notification above: the event's own workflow and
  # authorization state live elsewhere and are unaffected by this delete.
  # Ninety days after it occurred, whether read or unread, the projection
  # itself is removed. It is its own named window even though the value
  # matches `@delivery_notification_window` above.
  @participation_notification_window 90 * @day

  # A participation operational-security event is fixed, minimized evidence
  # of one security-relevant occurrence, not a durable record: it is deleted
  # 30 days after its own `occurred_at` through `ParticipationSecurityLog`'s
  # retention-capable local sink. It is its own named window even though the
  # value matches `@participation_window` above.
  @participation_security_log_window 30 * @day

  # A stable, arbitrary key so every instance contends for the same lock. It is
  # deliberately distinct from the whole-pruner key and from the personal
  # connection revocation sweep's key, so a contended revocation sweep never
  # silently suppresses snapshot expiry and neither one waits on the other.
  @snapshot_advisory_lock_key 529_140_776

  # Distinct again from the whole-pruner, revocation, and snapshot keys, so the
  # runtime accountability sweep neither waits on nor silently suppresses them.
  @runtime_advisory_lock_key 384_612_907

  # Deliberately distinct from all four keys above, so the observation sweep
  # neither waits on nor silently suppresses any of them.
  @observation_advisory_lock_key 271_058_349

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

  # A private project-assistant conversation is retained no later than 30
  # days after its own last activity (specs/12 Task 9, AC-21) — not its
  # creation time, matching `ProjectAssistantConversation.last_activity_at`'s
  # own touch-on-every-turn semantics. It is its own named window even
  # though the value matches `@participation_window` above.
  @project_assistant_conversation_window 30 * @day

  # Distinct from every other sweep's key in this codebase (including
  # `SddOrchestrator.Privacy.ParticipationPropagation`'s key, a different
  # module), so a contended project-assistant sweep neither waits on nor
  # silently suppresses any of them.
  @project_assistant_advisory_lock_key 703_881_642

  # An observation is the operational trail of one agent's run: elapsed time,
  # token counters, an estimated cost, the quota that applied, and the status at
  # that moment. Its purpose is operating and pausing work safely and answering
  # a near-term question about what a run was doing, which is the same purpose
  # and lifetime the deployment fixes for its operational security log at 30
  # days in `DeploymentPrivacyProfile.retention_requirements()`. Thirty days
  # after the observation that purpose is spent. What accountability still needs
  # — the configuration the run executed under and the cost reconciled against
  # its ceiling — is held by the session and its ledger for their own longer
  # windows, so deleting the per-observation trail earlier removes detail
  # without removing the account of the run. It is its own constant rather than
  # a read of the profile because this is stored data governed by this module
  # and not a log the deployment infrastructure expires, which is the same
  # reason the two session windows above are stated here.
  @runtime_observation_window 30 * @day

  # Guided-delivery temporary execution data — an inactive command and a
  # resolved blocking question — serves recovery, not history: it exists so a
  # dispatcher can redeliver an instruction and a later attempt can resume
  # accepted work. Once the run that could use it is no longer active and 30
  # days have passed since that purpose ended, nothing can still read it. It is
  # its own named window even though the value matches `@participation_window`
  # above, because it governs a different feature's lifecycle. A superseded
  # evidence artifact's stored bytes are released on this same window and for
  # the same reason: once a later result replaced it, the captured screenshot or
  # log proves nothing, and only the immutable provenance row is still history.
  @delivery_temporary_window 30 * @day

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

  @typedoc "Rows deleted by one runtime observation sweep."
  @type observation_counts :: %{expired_agent_runtime_observations: non_neg_integer()}

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
      participation_revocation_links: prune_participation_revocation_links(now),
      acknowledged_personal_ai_connections: reconcile_personal_ai_connections(now),
      revoked_personal_ai_connections: prune_revoked_personal_ai_connections(now),
      unstarted_repository_initialization_plans:
        prune_unstarted_repository_initialization_plans(now),
      expired_delivery_notifications: prune_delivery_notifications(now),
      expired_participation_email_delivery_diagnostics:
        prune_participation_email_delivery_diagnostics(now),
      expired_participation_notifications: prune_participation_notifications(now),
      expired_participation_security_events: prune_participation_security_events(now),
      expired_delivery_commands: prune_delivery_commands(now),
      expired_delivery_checkpoints: prune_delivery_checkpoints(now),
      expired_delivery_artifacts: prune_delivery_artifacts(now),
      expired_delivery_previews: prune_delivery_previews(now),
      released_delivery_attempt_leases: prune_delivery_attempt_leases(now),
      expired_device_delivery_commands: prune_device_delivery_commands(now),
      expired_device_delivery_checkpoints: prune_device_delivery_checkpoints(now),
      expired_device_delivery_artifacts: prune_device_delivery_artifacts(now),
      expired_device_delivery_previews: prune_device_delivery_previews(now)
    }
    |> Map.merge(snapshot_counts(now))
    |> Map.merge(runtime_counts(now))
    |> Map.merge(observation_counts(now))
    |> Map.merge(repository_initialization_run_counts(now))
    |> Map.merge(prune_project_assistant_conversations(now))
  end

  @doc false
  @spec snapshot_advisory_lock_key() :: pos_integer()
  def snapshot_advisory_lock_key, do: @snapshot_advisory_lock_key

  @doc false
  @spec runtime_advisory_lock_key() :: pos_integer()
  def runtime_advisory_lock_key, do: @runtime_advisory_lock_key

  @doc false
  @spec observation_advisory_lock_key() :: pos_integer()
  def observation_advisory_lock_key, do: @observation_advisory_lock_key

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

  @doc """
  Deletes every agent runtime observation whose operational window has passed.

  An observation is due once the window has elapsed since it was observed,
  independently of the accountability window its session and ledger serve.
  Returns `:locked` when another instance is sweeping; a contended sweep deletes
  nothing rather than duplicating the work. The delete is one bounded statement
  and therefore atomic, so an interrupted pass leaves no partial state and
  re-running converges.
  """
  @spec prune_ai_runtime_observations(DateTime.t()) :: observation_counts() | :locked
  def prune_ai_runtime_observations(now \\ DateTime.utc_now()) do
    now = DateTime.truncate(now, :second)
    cutoff = DateTime.add(now, -@runtime_observation_window, :second)

    with_advisory_lock(@observation_advisory_lock_key, "runtime observation sweep", fn ->
      {count, _} =
        Repo.delete_all(
          from observation in AgentRuntimeObservation,
            where: observation.observed_at <= ^cutoff
        )

      %{expired_agent_runtime_observations: count}
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

  @typedoc "Rows deleted by one project-assistant conversation sweep."
  @type project_assistant_counts :: %{
          expired_project_assistant_conversations: non_neg_integer(),
          expired_assistant_boundary_confirmations: non_neg_integer(),
          expired_device_project_assistant_conversations: non_neg_integer()
        }

  @doc """
  Deletes every project-assistant conversation whose retention boundary has
  passed (specs/12 Task 9, AC-21).

  A hosted conversation is due 30 days after its own last activity, or
  immediately once its account is no longer a current member (owner or
  active participant) of its project — the "participant departure triggers
  private-history cleanup" business rule, checked directly against current
  authoritative participation state on every sweep pass rather than through
  `SddOrchestrator.Participation.ParticipationRevocation`'s claim/acknowledge
  handoff. That handoff carries exactly one `acknowledged_at`/`consumer_ref`
  pair per departure (its own schema, and `Revocations.pending/1`'s
  `is_nil(acknowledged_at)` filter, both confirm this), so it supports
  exactly the one registered consumer it already has
  (`SddOrchestrator.Delivery.RevocationConsumer`); a second consumer
  claiming and acknowledging the same row would race that consumer for the
  single acknowledgement slot rather than running independently, and
  `acknowledge_changeset/3` releases the very `former_account_id` a second
  consumer would need. Re-deriving current membership directly is the same
  fail-closed, re-asked-on-every-call authorization every other
  project-assistant surface already uses
  (`SddOrchestrator.ProjectAssistant.Guard`), so departure takes effect on
  this sweep's very next pass without depending on another specification's
  single-consumer mechanism at all.

  A hosted conversation's turns and citations cascade with it through their
  own `on_delete: :delete_all` foreign keys. A matching
  `AssistantBoundaryConfirmation` (same project and account) is deleted in
  the same pass once its own matching conversation is itself due, or
  immediately once its account is no longer a current member — never
  purely on its own `confirmed_at` age while its conversation (if any)
  remains active, because unlike conversation history's "last activity"
  window, a confirmation stays valid for as long as the disclosed boundary
  has not materially changed (AC-06), however long that is; pruning it on a
  timer regardless of ongoing activity would force a needless
  reconfirmation on an active, ongoing conversation. A participant who
  confirmed the boundary before ever asking a first question has no
  conversation yet at all, so their confirmation is pruned only by the
  departure trigger, never by a timer with nothing to measure against.

  A device-authoritative conversation has no multi-participant concept (see
  `SddOrchestrator.ProjectAssistant.Guard`'s own moduledoc: a device project
  has no hosted owner or participant), so only the 30-day inactivity rule
  applies there, swept through `SddOrchestrator.Devices`' already-public
  delivery API — matching every other device-sweep clause in this module
  (see `prune_device_import_attempts/1`) rather than a project-assistant-
  specific addition to the device store.

  Returns `:locked` (mapped to a zero count) for the hosted half when
  another instance already holds its advisory lock; the device half is
  unaffected since it never contends with another node, matching
  `prune_device_import_attempts/1`'s own independence from the hosted locks.
  """
  @spec prune_project_assistant_conversations(DateTime.t()) :: project_assistant_counts()
  def prune_project_assistant_conversations(now \\ DateTime.utc_now()) do
    now = DateTime.truncate(now, :second)
    cutoff = DateTime.add(now, -@project_assistant_conversation_window, :second)

    hosted =
      with_advisory_lock(
        @project_assistant_advisory_lock_key,
        "project assistant conversation sweep",
        fn -> delete_due_project_assistant_records(cutoff) end
      )

    hosted =
      case hosted do
        :locked ->
          %{
            expired_project_assistant_conversations: 0,
            expired_assistant_boundary_confirmations: 0
          }

        counts ->
          counts
      end

    Map.put(
      hosted,
      :expired_device_project_assistant_conversations,
      prune_device_project_assistant_conversations(cutoff)
    )
  end

  # The confirmation delete runs first, while its own matching conversation
  # row (if any) still exists for `due_assistant_boundary_confirmation_query/1`'s
  # subquery to judge due against; deleting conversations first would leave
  # nothing for that subquery to match, silently under-counting.
  defp delete_due_project_assistant_records(cutoff) do
    {confirmations, _} = Repo.delete_all(due_assistant_boundary_confirmation_query(cutoff))
    {conversations, _} = Repo.delete_all(due_project_assistant_conversation_query(cutoff))

    %{
      expired_project_assistant_conversations: conversations,
      expired_assistant_boundary_confirmations: confirmations
    }
  end

  defp due_project_assistant_conversation_query(cutoff) do
    from(c in ProjectAssistantConversation,
      as: :governed,
      join: project in Project,
      on: project.id == c.project_id,
      join: owner_workspace in PersonalWorkspace,
      on: owner_workspace.id == project.workspace_id,
      where:
        c.last_activity_at <= ^cutoff or
          (owner_workspace.account_id != c.account_id and
             not exists(active_participant_exists_subquery()))
    )
  end

  # Due when its own matching conversation (same project and account) is
  # itself due for the 30-day-inactivity reason, so a confirmation never
  # outlives the conversation it gates access to; or immediately once its
  # account is no longer a current member — the same departure trigger the
  # conversation query above uses, independent of whether a conversation
  # exists at all (a participant may confirm before ever asking a first
  # question). Never due purely on its own `confirmed_at` age with a still-
  # current, still-active conversation — see this function's caller's own
  # moduledoc paragraph for why.
  defp due_assistant_boundary_confirmation_query(cutoff) do
    matching_conversation_due_subquery =
      from(c in ProjectAssistantConversation,
        where: c.project_id == parent_as(:governed).project_id,
        where: c.account_id == parent_as(:governed).account_id,
        where: c.last_activity_at <= ^cutoff,
        select: 1
      )

    from(bc in AssistantBoundaryConfirmation,
      as: :governed,
      join: project in Project,
      on: project.id == bc.project_id,
      join: owner_workspace in PersonalWorkspace,
      on: owner_workspace.id == project.workspace_id,
      where:
        exists(matching_conversation_due_subquery) or
          (owner_workspace.account_id != bc.account_id and
             not exists(active_participant_exists_subquery()))
    )
  end

  # Correlated to the outer `:governed` binding (the conversation or
  # confirmation row currently being judged), mirroring
  # `SddOrchestrator.Participation.Boundary.current_participants/1`'s exact
  # join shape (`ProjectParticipant` to `HostedIdentity` on
  # `hosted_identity_id`, filtered to the project and `state == "active"`)
  # rather than re-deriving a different membership rule.
  defp active_participant_exists_subquery do
    from(p in ProjectParticipant,
      join: identity in HostedIdentity,
      on: identity.id == p.hosted_identity_id,
      where: p.project_id == parent_as(:governed).project_id,
      where: identity.account_id == parent_as(:governed).account_id,
      where: p.state == "active",
      select: 1
    )
  end

  defp prune_device_project_assistant_conversations(cutoff) do
    Devices.list_projects()
    |> Enum.reduce(0, fn project, count ->
      count + sweep_one_device_project_assistant_conversation(project.id, cutoff)
    end)
  catch
    :exit, _unavailable_store -> 0
  end

  defp sweep_one_device_project_assistant_conversation(project_id, cutoff) do
    project_id
    |> Devices.list_delivery(:project_assistant_conversation)
    |> Enum.flat_map(&decode_device_conversation/1)
    |> Enum.filter(&(DateTime.compare(&1.last_activity_at, cutoff) != :gt))
    |> Enum.map(&delete_device_project_assistant_conversation(project_id, &1))
    |> Enum.count(&(&1 == :ok))
  end

  defp decode_device_conversation(value) do
    case DeviceProjectAssistantConversation.from_value(value) do
      {:ok, conversation} -> [conversation]
      {:error, _reason} -> []
    end
  end

  defp delete_device_project_assistant_conversation(project_id, conversation) do
    result =
      Devices.commit_delivery(project_id, [
        {:put, :project_assistant_conversation, conversation.id, %{"deleted" => true},
         conversation.state_version}
      ])

    delete_device_assistant_boundary_confirmation(project_id, conversation.id)

    case result do
      {:ok, _applied} -> :ok
      {:error, _reason} -> :error
    end
  end

  # The device conversation and its boundary confirmation share the same
  # key (the device workspace id): there is exactly one possible participant
  # per device-authoritative project, so no separate lookup is needed to
  # find the matching confirmation.
  defp delete_device_assistant_boundary_confirmation(project_id, workspace_id) do
    case Devices.get_delivery(project_id, :assistant_boundary_confirmation, workspace_id) do
      {:ok, value} ->
        Devices.commit_delivery(project_id, [
          {:put, :assistant_boundary_confirmation, workspace_id, %{"deleted" => true},
           value["state_version"]}
        ])

        :ok

      {:error, :not_found} ->
        :ok
    end
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

  # The observation sweep runs last, after the session sweep, for the same
  # reason the snapshot sweep runs after the terminal-connection delete: a
  # session deleted earlier in this pass has already cascaded its observations
  # away, so this count reports only the rows the observation window itself
  # removed and never double-counts what the cascade removed.
  defp observation_counts(now) do
    case prune_ai_runtime_observations(now) do
      :locked -> %{expired_agent_runtime_observations: 0}
      counts -> counts
    end
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

  # A `delivery.`-namespace notification is deleted 90 days after its own
  # `occurred_at`, whether read or unread — read state is never filtered on.
  # Slice 08's `participation.`-namespace rows on the same schema are excluded
  # by the `like` prefix and are never selected here.
  defp prune_delivery_notifications(now) do
    cutoff = DateTime.add(now, -@delivery_notification_window, :second)

    {count, _} =
      Repo.delete_all(
        from notification in AccountNotification,
          where:
            like(notification.event_type, "delivery.%") and
              notification.occurred_at <= ^cutoff
      )

    count
  end

  # A `participation.`-namespace notification is deleted 90 days after its own
  # `occurred_at`, whether read or unread — read state is never filtered on.
  # The `delivery.`-namespace rows above are excluded by the `like` prefix and
  # are never selected here, and a row outside the approved notification
  # vocabulary carries neither prefix and is never selected either.
  defp prune_participation_notifications(now) do
    cutoff = DateTime.add(now, -@participation_notification_window, :second)

    {count, _} =
      Repo.delete_all(
        from notification in AccountNotification,
          where:
            like(notification.event_type, "participation.%") and
              notification.occurred_at <= ^cutoff
      )

    count
  end

  # A fixed, minimized participation security event is deleted 30 days after
  # its own occurred_at through ParticipationSecurityLog's retention-capable
  # local sink, which owns the table and the delete statement itself; this
  # rule only supplies the window and the call, mirroring how
  # `prune_device_import_attempts/1` above delegates to its own domain
  # module's deletion function.
  defp prune_participation_security_events(now) do
    cutoff = DateTime.add(now, -@participation_security_log_window, :second)
    SddOrchestrator.Privacy.ParticipationSecurityLog.prune(cutoff)
  end

  # A finalized ("sent" or "failed") diagnostic is deleted 30 days after its
  # authoritative attempt or completion time: `delivered_at` when present,
  # otherwise `attempted_at`. A "pending" row is never selected — it still
  # represents retry state, not evidence whose short diagnostic purpose has
  # ended — and only the diagnostic row itself is deleted, never the
  # invitation, participant, profile, revocation, or account it references.
  defp prune_participation_email_delivery_diagnostics(now) do
    cutoff = DateTime.add(now, -@participation_email_delivery_window, :second)

    {count, _} =
      Repo.delete_all(
        from delivery in ParticipationEmailDelivery,
          where:
            delivery.status in ["sent", "failed"] and
              fragment("COALESCE(?, ?)", delivery.delivered_at, delivery.attempted_at) <= ^cutoff
      )

    count
  end

  # An acknowledged or failed command has already done the only thing it exists
  # to do. Its purpose ended when the worker answered (`acknowledged_at`, set by
  # both the acknowledgement and the terminal-failure transition) or, for a row
  # that reached a terminal state without one, when it was last written
  # (`updated_at`). Thirty days later the whole row goes: it carries only
  # execution mechanics — the operation, the manifest digest, the claim, the
  # result, and the failure code — and no participant-visible text, so there is
  # nothing in it to keep once redelivery and replay can no longer be asked for.
  defp prune_delivery_commands(now) do
    cutoff = DateTime.add(now, -@delivery_temporary_window, :second)

    {count, _} =
      Repo.delete_all(
        from command in RunCommand,
          as: :governed,
          where:
            command.state in ^RunCommand.terminal_states() and
              fragment("COALESCE(?, ?)", command.acknowledged_at, command.updated_at) <= ^cutoff and
              not exists(active_delivery_run_subquery())
      )

    count
  end

  # A resolved blocking question is the worker's resume aid and nothing else:
  # the checkpoint, the branch, and the worker-local workspace path a later
  # attempt would continue accepted work from. `updated_at` is the resolution
  # time because resolving is the transition that bumps `state_version`, and
  # there is deliberately no separate `resolved_at` column. Thirty days after
  # that resolution the whole row is deleted rather than emptied, because the
  # participant-visible question and its answer are not stored here at all —
  # they are duplicated into `activity_entries` as `"question_asked"` and
  # `"question_answered"`, which survive this delete untouched and are governed
  # by their own lifecycle. Keeping the row would leave a path from the
  # developer's own machine stored indefinitely for no remaining purpose.
  defp prune_delivery_checkpoints(now) do
    cutoff = DateTime.add(now, -@delivery_temporary_window, :second)

    {count, _} =
      Repo.delete_all(
        from question in BlockingQuestion,
          as: :governed,
          where:
            question.state in ^BlockingQuestion.resolved_states() and
              question.updated_at <= ^cutoff and
              not exists(active_delivery_run_subquery())
      )

    count
  end

  # Correlated to the outer `:governed` binding (the command or question
  # currently being judged). Age alone is not enough to release either row: a
  # run that has not reached `"failed"`, `"canceled"`, or `"completed"` can
  # still be resumed, retried, or reconciled, and both rows are exactly what
  # that recovery reads. So an old terminal command or resolved question of a
  # still-`"running"` or `"blocked"` run is kept, and becomes due only once its
  # run itself ends.
  defp active_delivery_run_subquery do
    from(run in AgentRun,
      where: run.id == parent_as(:governed).run_id,
      where: run.state not in ^AgentRun.terminal_states(),
      select: 1
    )
  end

  # Releases the stored bytes of superseded evidence, and nothing else. No
  # `evidence` row is deleted or updated here, by this function or anything it
  # calls: the supersession link, the reference, the digest, and the recorded
  # time are the provenance a reader follows, the database itself refuses to
  # rewrite them, and the intended end state is a row that still names a
  # reference whose content is gone. What expires is the captured screenshot or
  # log, which stopped being proof of anything the moment a later result
  # replaced it.
  #
  # The count is what the store actually still held, not how many references
  # were judged due, because `ArtifactStore.delete/3` answers `:ok` for content
  # that is already absent. Two rows superseded a month apart can name the same
  # digest, so the second sweep must report nothing rather than re-counting a
  # deletion the first one already made.
  defp prune_delivery_artifacts(now) do
    cutoff = DateTime.add(now, -@delivery_temporary_window, :second)

    cutoff
    |> released_artifact_refs()
    |> Enum.reduce(0, fn {workspace_id, project_id, refs}, count ->
      count + delete_released_artifacts(%PersonalWorkspace{id: workspace_id}, project_id, refs)
    end)
  end

  # The supersession instant is the replacement row's `inserted_at`, reached
  # through `superseded_by_id`. `evidence` has no `updated_at` and no
  # `superseded_at` — its create migration says so deliberately, and the
  # `evidence_reject_rewrite` trigger freezes every column but the supersession
  # link — so there is no timestamp on the superseded row itself that moved when
  # it was superseded. The replacement is inserted in the same atomic commit as
  # that link (`EvidenceIngestion`'s `:evidence` and `:superseded` steps, the
  # second referencing the first), which makes its server-written `inserted_at`
  # the exact moment the older result stopped being current, and one no worker
  # can backdate the way it can choose its own `recorded_at`. The join is inner,
  # so a row that was never superseded is not a candidate at all.
  defp released_artifact_refs(cutoff) do
    from(evidence in Evidence,
      as: :governed,
      join: replacement in Evidence,
      on: replacement.id == evidence.superseded_by_id,
      join: project in Project,
      on: project.id == evidence.project_id,
      where: not is_nil(evidence.artifact_ref),
      where: replacement.inserted_at <= ^cutoff,
      where: not exists(still_needed_evidence_subquery(cutoff)),
      distinct: true,
      select: {project.workspace_id, evidence.project_id, evidence.artifact_ref}
    )
    |> Repo.all()
    |> Enum.group_by(
      fn {workspace_id, project_id, _ref} -> {workspace_id, project_id} end,
      fn {_workspace_id, _project_id, ref} -> ref end
    )
    |> Enum.map(fn {{workspace_id, project_id}, refs} -> {workspace_id, project_id, refs} end)
  end

  # The check that keeps this rule from destroying accepted evidence. An
  # artifact is addressed by the digest of its own content within its own
  # project, so a rerun that produced byte-identical output, and a current row
  # and a superseded row describing the same capture, all name one stored
  # object. Deleting on the strength of the expired row alone would take the
  # bytes out from under every other row naming it.
  #
  # Correlated to the outer `:governed` binding: it asks whether any row of the
  # same project names the same reference while still needing it — either
  # current, or superseded too recently for its own window to have passed. One
  # such row anywhere keeps the content. Same-project is the whole question:
  # both adapters key an artifact by `(project, digest)` and every read is
  # scoped to the project that owns it, so a matching digest under another
  # project is a different stored object this delete cannot reach.
  defp still_needed_evidence_subquery(cutoff) do
    from(other in Evidence,
      left_join: other_replacement in Evidence,
      on: other_replacement.id == other.superseded_by_id,
      where: other.project_id == parent_as(:governed).project_id,
      where: other.artifact_ref == parent_as(:governed).artifact_ref,
      where: is_nil(other.superseded_by_id) or other_replacement.inserted_at > ^cutoff,
      select: 1
    )
  end

  # One `list_refs/2` per project rather than a `stat/3` per reference: it reads
  # no bytes, and it answers for every candidate at once what a repeat sweep
  # needs to know — that the content is already gone, so this pass removed
  # nothing and must say so.
  defp delete_released_artifacts(authority, project_id, refs) do
    held = MapSet.new(ArtifactStore.list_refs(authority, project_id))

    refs
    |> Enum.filter(&MapSet.member?(held, &1))
    |> Enum.map(&ArtifactStore.delete(authority, project_id, &1))
    |> Enum.count(&(&1 == :ok))
  end

  # A preview stops being useful at a knowable instant whichever way it stopped
  # — it expired, a later attempt replaced it, its request ran past the
  # deadline, or the provider refused it — and 30 days after that instant the
  # record of the deployment goes. What it carries is the provider's opaque
  # handle, the one
  # participant-safe link, and the deployment's own timings — a convenience that
  # was never a verdict — so nothing about the feature, the run, the attempt, the
  # activity history, or the evidence depends on it still being there.
  #
  # The hazard this rule is shaped around is the *remote* half. A preview
  # deployment has a counterpart at a preview provider, and `cleanup_state` is
  # the only record of whether that counterpart is gone: `"none"` means the
  # release is still owed (the processing inventory says so in exactly those
  # words), `"requested"` that the command was made durable but the provider
  # never confirmed, `"failed"` that the provider refused it, and `"done"` that
  # `SddOrchestrator.Delivery.Previews.cleanup/4` saw the adapter answer `:ok`.
  # Deleting a row in any of the first three would orphan a deployment nothing
  # can ever name again, and it may go on serving the project's content
  # publicly; a retained row costs storage, an orphaned preview is an exposure
  # with no owner. So only `"done"` is released, however old the rest are.
  #
  # `"expired"` in particular is not itself proof the remote is gone: when a
  # provider states no expiry of its own, `Previews` applies the *configured*
  # ttl, so an expired status can be the control plane's own deadline rather
  # than anything the provider reclaimed.
  defp prune_delivery_previews(now) do
    # Every timestamp on `preview_deployments` is `:utc_datetime_usec`, unlike
    # the second-precision columns the rules above compare against, so the
    # cutoff is widened rather than truncated: Ecto refuses to dump a
    # second-precision value against a microsecond column instead of comparing
    # it.
    cutoff =
      now
      |> DateTime.add(-@delivery_temporary_window, :second)
      |> DateTime.add(0, :microsecond)

    due = cutoff |> due_preview_deployment_ids() |> Repo.all() |> MapSet.new()
    releasable = releasable_preview_deployment_ids(due)

    {count, _} =
      Repo.delete_all(
        from deployment in PreviewDeployment,
          where: deployment.id in ^MapSet.to_list(releasable)
      )

    count
  end

  # Four statuses, four instants, one cutoff. Each branch names the timestamp
  # that actually ended that preview's purpose rather than sharing one
  # approximation across all of them:
  #
  #   * `"expired"` — `expires_at`, when it stopped being reachable, falling
  #     back to `updated_at` for a provider that reported the status without
  #     ever stating a time.
  #   * `"superseded"` — the replacement's `inserted_at`, written beside the
  #     supersession link in one atomic commit and frozen afterwards by the
  #     binding trigger. This row's own `expires_at` is deliberately not
  #     consulted: it answers when that preview stopped being reachable, not
  #     when a later attempt made it the wrong one to look at, and the two can
  #     be months apart in either direction.
  #   * `"timed_out"` — `timeout_at`, the deadline the request policy set and
  #     the very value `Previews.settle/3` compares against to declare the
  #     timeout, so the row is measured from when the preview stopped being
  #     useful and not from whenever a later poll noticed.
  #   * `"failed"` — `updated_at` alone. A provider refusal records no expiry
  #     (`Previews.stopped/2` writes `nil`) and the deadline it never reached
  #     says nothing about it, so the failure write is the only instant the row
  #     has and none is invented for it.
  #
  # The open-status guard is the invariant stated once rather than left implied
  # by the absence of a branch: a `"pending"` or `"ready"` preview is the one a
  # reviewer still opens, and no age releases it. The left join is what lets a
  # single statement carry all four, since only the superseded branch has a
  # replacement row to reach.
  defp due_preview_deployment_ids(cutoff) do
    from(deployment in PreviewDeployment,
      left_join: replacement in PreviewDeployment,
      on: replacement.id == deployment.superseded_by_id,
      where: deployment.cleanup_state == "done",
      where: deployment.status not in ^PreviewDeployment.open_statuses(),
      where:
        (deployment.status == "expired" and
           fragment("COALESCE(?, ?)", deployment.expires_at, deployment.updated_at) <= ^cutoff) or
          (deployment.status == "superseded" and replacement.inserted_at <= ^cutoff) or
          (deployment.status == "timed_out" and deployment.timeout_at <= ^cutoff) or
          (deployment.status == "failed" and deployment.updated_at <= ^cutoff),
      select: deployment.id
    )
  end

  # A due row that a *retained* deployment still names through `superseded_by_id`
  # is held back until that one is due as well. The foreign key is
  # `on_delete: :nilify_all`, and clearing the link of a row whose status is
  # still `"superseded"` violates `preview_deployments_supersession_pairing`,
  # which would abort the whole pass rather than skip one row. Deleting both in
  # the same statement is fine — the referential action finds nothing left to
  # null — so this only ever defers a row to the pass where its own referrer
  # becomes releasable, most often once that referrer's provider cleanup
  # finally succeeds.
  #
  # Being due is not the same as being deleted, so the set is closed rather than
  # filtered once, exactly as `releasable_device_preview_ids/2` closes the
  # device half: holding one row back makes it a retained referrer in its own
  # right, and a chain of supersessions would otherwise strand its middle. In
  # `A -> B -> C`, a single filter keeps `B` because retained `A` names it, then
  # releases `C` because its only referrer `B` was in the due set — the very row
  # just held back — and nulling the held-back `B`'s link is the abort this rule
  # exists to prevent. Each round drops at least one id, so the recursion
  # terminates.
  defp releasable_preview_deployment_ids(due) do
    close_releasable_preview_ids(referring_preview_links(due), due)
  end

  defp close_releasable_preview_ids(links, releasable) do
    strandable =
      MapSet.intersection(releasable, ids_named_by_retained_preview_links(links, releasable))

    if MapSet.size(strandable) == 0 do
      releasable
    else
      close_releasable_preview_ids(links, MapSet.difference(releasable, strandable))
    end
  end

  # Every supersession link that could ever strand a candidate, read once. A
  # link whose target is not a candidate cannot hold anything back, and a
  # candidate with no link named at it cannot be stranded, so restricting the
  # read to the candidates is the whole relation this closure needs rather than
  # a sample of it.
  defp referring_preview_links(due) do
    Repo.all(
      from other in PreviewDeployment,
        where: other.superseded_by_id in ^MapSet.to_list(due),
        select: {other.id, other.superseded_by_id}
    )
  end

  defp ids_named_by_retained_preview_links(links, releasable) do
    links
    |> Enum.reject(fn {referrer_id, _target_id} -> MapSet.member?(releasable, referrer_id) end)
    |> MapSet.new(fn {_referrer_id, target_id} -> target_id end)
  end

  # A lease claim is operational data with a short purpose: it names the one
  # worker allowed to execute an attempt and until when. Once the attempt is
  # terminal that purpose is over — a terminal attempt can take no further
  # transition, so no worker can ever act under the claim again — and what the
  # row still carries is the worker's identity string. Thirty days after the
  # attempt finished the claim goes, on the same window and for the same reason
  # as the temporary execution data above.
  #
  # This is an update and never a delete. The attempt itself, its outcome, its
  # number, and its fence are the participant-visible account of what the run
  # did; they belong to the delivery lifecycle and are removed with the run,
  # not by this rule. Nothing here touches `state`, `state_version`,
  # `last_sequence`, `required_checks`, or any revision or manifest digest.
  #
  # "Finished" is `updated_at` because `run_attempts` has no `finished_at`
  # column and needs none: `RunAttempt.transitions/0` gives every terminal
  # state an empty target list, so the write that made the attempt terminal is
  # by construction the last write it can take. `updated_at` is deliberately
  # left alone by the update as well — it is the very instant this rule
  # measures, and overwriting it would erase when the attempt ended and make a
  # released row look freshly written.
  #
  # Both columns are cleared in one statement because
  # `run_attempts_lease_pairing` requires them null together or non-null
  # together; setting one alone raises the check violation and aborts the whole
  # `prune_all/1` pass. `fence_token` is not part of the release: it is
  # `null: false`, constrained positive, and unique within its run, and it is
  # what keeps a superseded worker's late events rejected, so it expires with
  # the attempt row under the delivery lifecycle rather than on this window.
  defp prune_delivery_attempt_leases(now) do
    cutoff = DateTime.add(now, -@delivery_temporary_window, :second)

    {count, _} =
      Repo.update_all(
        from(attempt in RunAttempt,
          where: attempt.state in ^RunAttempt.terminal_states(),
          where: attempt.updated_at <= ^cutoff,
          # Only a claim still held is counted, so the number describes rows
          # this pass actually released and a repeat pass reports nothing. The
          # pairing constraint makes testing the owner alone sufficient: a row
          # with an expiry and no owner cannot exist.
          where: not is_nil(attempt.lease_owner)
        ),
        set: [lease_owner: nil, lease_expires_at: nil]
      )

    count
  end

  # The device-authoritative half of the same lifecycle, on the same window and
  # the same eligibility rule: a terminal command whose purpose ended more than
  # 30 days ago and whose run is no longer active. Eligibility is decided inside
  # the device authority — the records are read from `SddOrchestrator.Devices`'
  # already-public delivery API and judged there — because a device project has
  # no hosted row at all, and copying one out to decide what to prune would
  # create exactly the hosted copy this authority exists to avoid.
  defp prune_device_delivery_commands(now) do
    cutoff = DateTime.add(now, -@delivery_temporary_window, :second)

    Devices.list_projects()
    |> Enum.reduce(0, fn project, count ->
      count + sweep_one_device_project_delivery(project.id, :command, cutoff)
    end)
  catch
    # An offline, unpaired, or unreachable worker pauses this rule instead of
    # aborting the pass: nothing on that device is due until it can be asked
    # again, and every hosted rule in `prune_all/1` still runs.
    :exit, _unavailable_store -> 0
  end

  # The device-authoritative resolved checkpoint, on the same window and the
  # same run-still-active exclusion as its hosted counterpart, resolved inside
  # the device authority for the same reason as the command sweep above.
  defp prune_device_delivery_checkpoints(now) do
    cutoff = DateTime.add(now, -@delivery_temporary_window, :second)

    Devices.list_projects()
    |> Enum.reduce(0, fn project, count ->
      count + sweep_one_device_project_delivery(project.id, :question, cutoff)
    end)
  catch
    :exit, _unavailable_store -> 0
  end

  defp sweep_one_device_project_delivery(project_id, kind, cutoff) do
    active_run_ids = active_device_run_ids(project_id)

    project_id
    |> Devices.list_delivery(kind)
    |> Enum.filter(&due_device_delivery_record?(kind, &1, cutoff, active_run_ids))
    |> Enum.map(&tombstone_device_delivery_record(project_id, kind, &1))
    |> Enum.count(&(&1 == :ok))
  end

  # The device value shape carries no Ecto timestamps at all — `to_value/1`
  # deliberately exposes no `acknowledged_at`, `updated_at`, or `resolved_at`
  # — so each record is measured by the only instant it does carry. For a
  # command that is `due_at`, the last time the instruction was scheduled for
  # delivery, which for a terminal command is the delivery it answered; for a
  # question it is `asked_at`, and a resolution can only have happened at or
  # after it. Both are at or before the hosted rule's own purpose-ended time,
  # so the device half never retains a record longer than the hosted half
  # would, which is the direction data minimisation must err in.
  defp due_device_delivery_record?(:command, value, cutoff, active_run_ids) do
    case RunCommand.from_value(value) do
      {:ok, command} ->
        command.state in RunCommand.terminal_states() and
          DateTime.compare(command.due_at, cutoff) != :gt and
          command.run_id not in active_run_ids

      {:error, _reason} ->
        false
    end
  end

  defp due_device_delivery_record?(:question, value, cutoff, active_run_ids) do
    case BlockingQuestion.from_value(value) do
      {:ok, question} ->
        question.state in BlockingQuestion.resolved_states() and
          DateTime.compare(question.asked_at, cutoff) != :gt and
          question.run_id not in active_run_ids

      {:error, _reason} ->
        false
    end
  end

  # The device equivalent of the hosted `not exists(active_delivery_run_subquery())`:
  # a command or question whose run has not reached `"failed"`, `"canceled"`, or
  # `"completed"` is current recovery material whatever its age. A record whose
  # run is absent from the store has no active run and is released by age alone,
  # exactly as the hosted `not exists` clause decides it.
  defp active_device_run_ids(project_id) do
    project_id
    |> Devices.list_delivery(:run)
    |> Enum.flat_map(fn value ->
      case AgentRun.from_value(value) do
        {:ok, run} -> [run]
        {:error, _reason} -> []
      end
    end)
    |> Enum.reject(&AgentRun.terminal?/1)
    |> MapSet.new(& &1.id)
  end

  # A tombstone put, never a key delete: the delivery seam applies puts and
  # nothing else (see `SddOrchestrator.Delivery.ArtifactStore.Device`), so the
  # record is replaced by the bare fact that this key is no longer a command or
  # a question. The tombstone carries no operation, result, checkpoint, branch,
  # or workspace path — nothing of the expired record survives it, and every
  # decode treats it as absent. The expected version is the one the record
  # itself carries (`nil` for a command, which has no `state_version` in its
  # value shape), so a record rewritten since this sweep read it is refused
  # rather than overwritten, and is judged again on the next pass.
  defp tombstone_device_delivery_record(project_id, kind, value) do
    project_id
    |> Devices.commit_delivery([
      {:put, kind, value["id"], %{"deleted" => true}, value["state_version"]}
    ])
    |> case do
      {:ok, _applied} -> :ok
      {:error, _reason} -> :error
    end
  end

  # The device-authoritative half of the superseded-artifact rule, on the same
  # window, the same digest-safety check, and the same refusal to touch the
  # record. No evidence record is written, tombstoned, or removed here, by this
  # function or anything it calls: only the stored bytes go, and the intended
  # end state is a record that still names a reference whose content is gone.
  #
  # Eligibility is resolved inside the device authority. A device project has no
  # hosted `evidence` row to join against, and copying one out to decide what to
  # prune would create exactly the hosted copy this authority exists to avoid,
  # so the records are read from `SddOrchestrator.Devices`' delivery API and
  # judged there. The release itself reuses the hosted rule's own
  # `delete_released_artifacts/3` against a `DeviceWorkspace` authority, which is
  # what makes the count mean the same thing on both sides: what the store
  # actually still held, so a second pass reports nothing.
  defp prune_device_delivery_artifacts(now) do
    cutoff = DateTime.add(now, -@delivery_temporary_window, :second)

    Devices.list_projects()
    |> Enum.reduce(0, fn project, count ->
      count + sweep_one_device_project_artifacts(project, cutoff)
    end)
  catch
    # An offline, unpaired, or unreachable worker pauses this rule instead of
    # aborting the pass: nothing on that device is due until it can be asked
    # again, and every hosted rule in `prune_all/1` still runs.
    :exit, _unavailable_store -> 0
  end

  defp sweep_one_device_project_artifacts(project, cutoff) do
    project.id
    |> decoded_device_evidence()
    |> released_device_artifact_refs(cutoff)
    |> case do
      # Nothing due asks the store nothing further: there is no reference whose
      # presence the count would depend on.
      [] ->
        0

      refs ->
        delete_released_artifacts(
          %DeviceWorkspace{id: project.workspace_id},
          project.id,
          refs
        )
    end
  end

  defp decoded_device_evidence(project_id) do
    project_id
    |> Devices.list_delivery(:evidence)
    |> Enum.flat_map(fn value ->
      case Evidence.from_value(value) do
        {:ok, evidence} -> [evidence]
        {:error, _reason} -> []
      end
    end)
  end

  # `released_artifact_refs/1` and `still_needed_evidence_subquery/1` expressed
  # over one project's own records rather than over a join, and deciding the
  # same thing: a reference is released only when *no* record of this project
  # still needs it. Artifacts are digest-addressed, so a rerun that produced
  # byte-identical output and the item it replaced are one stored object, and
  # releasing on the strength of the expired record alone would take the bytes
  # out from under accepted evidence that still names them. Same-project is the
  # whole question, exactly as hosted: the device adapter keys an artifact by
  # `(project, digest)`, so a matching digest under another project is a
  # different stored object this delete cannot reach.
  defp released_device_artifact_refs(records, cutoff) do
    by_id = Map.new(records, &{&1.id, &1})

    still_needed =
      records
      |> Enum.filter(&device_evidence_still_needed?(&1, by_id, cutoff))
      |> MapSet.new(& &1.artifact_ref)

    records
    |> Enum.filter(&device_artifact_released?(&1, by_id, cutoff))
    |> Enum.map(& &1.artifact_ref)
    |> Enum.reject(&MapSet.member?(still_needed, &1))
    |> Enum.uniq()
  end

  # A record that never named an artifact is neither a candidate nor a claim on
  # one, exactly as the hosted query's `not is_nil(evidence.artifact_ref)` and
  # its subquery's reference equality decide it.
  defp device_artifact_released?(%Evidence{artifact_ref: ref}, _by_id, _cutoff)
       when not is_binary(ref),
       do: false

  defp device_artifact_released?(record, by_id, cutoff) do
    case device_supersession(record, by_id) do
      {:superseded_at, at} -> DateTime.compare(at, cutoff) != :gt
      _not_datable -> false
    end
  end

  defp device_evidence_still_needed?(%Evidence{artifact_ref: ref}, _by_id, _cutoff)
       when not is_binary(ref),
       do: false

  defp device_evidence_still_needed?(record, by_id, cutoff) do
    case device_supersession(record, by_id) do
      :current -> true
      {:superseded_at, at} -> DateTime.compare(at, cutoff) == :gt
      :undatable -> false
    end
  end

  # The supersession instant is the *replacement* record's `recorded_at`, found
  # by id in the same project's own listing. This is the one place the device
  # half deliberately measures something different from the hosted half, which
  # uses the replacement row's server-written `inserted_at`: `Evidence.to_value/1`
  # emits `recorded_at` and no Ecto timestamp at all, so there is no
  # server-written instant to carry across the device seam — and on a device the
  # worker that recorded the replacement is the authority for when its own
  # result happened, so there is no server clock to prefer over it.
  #
  # A record naming a replacement the store does not hold is `:undatable`: its
  # supersession cannot be placed against the window, so it neither releases its
  # own bytes nor holds anyone else's. That is the same outcome the hosted
  # rule's left join produces for a missing replacement, which its foreign key
  # makes unreachable and the device store does not.
  defp device_supersession(%Evidence{superseded_by_id: nil}, _by_id), do: :current

  defp device_supersession(%Evidence{superseded_by_id: replacement_id}, by_id) do
    case Map.fetch(by_id, replacement_id) do
      {:ok, replacement} -> {:superseded_at, replacement.recorded_at}
      :error -> :undatable
    end
  end

  # The device-authoritative half of the terminal-preview rule, on the same
  # window, the same terminal-status boundary, and the same confirmed-remote
  # guard. Eligibility is resolved inside the device authority — the records are
  # read from `SddOrchestrator.Devices`' delivery API and judged there — because
  # a device project has no hosted `preview_deployments` row at all, and copying
  # one out to decide what to prune would create exactly the hosted copy this
  # authority exists to avoid.
  #
  # The hazard the rule is shaped around does not soften on a device. A worker's
  # preview is still served by a provider, `cleanup_state` is still the only
  # record of whether that counterpart was torn down, and removing the record
  # while its release is owed, unconfirmed, or refused still leaves a deployment
  # nothing can ever name again.
  defp prune_device_delivery_previews(now) do
    cutoff = DateTime.add(now, -@delivery_temporary_window, :second)

    Devices.list_projects()
    |> Enum.reduce(0, fn project, count ->
      count + sweep_one_device_project_previews(project.id, cutoff)
    end)
  catch
    # An offline, unpaired, or unreachable worker pauses this rule instead of
    # aborting the pass: nothing on that device is due until it can be asked
    # again, and every hosted rule in `prune_all/1` still runs.
    :exit, _unavailable_store -> 0
  end

  # One listing per project, decoded once and indexed by id. Both questions this
  # rule asks beyond a single record — which replacement dates a superseded one,
  # and which records name a record that is about to go — are answered from that
  # same read rather than from a second trip to the worker.
  defp sweep_one_device_project_previews(project_id, cutoff) do
    records = decoded_device_previews(project_id)
    by_id = Map.new(records, &{&1.id, &1})

    due =
      records
      |> Enum.filter(&device_preview_due?(&1, by_id, cutoff))
      |> MapSet.new(& &1.id)

    releasable = releasable_device_preview_ids(records, due)

    records
    |> Enum.filter(&MapSet.member?(releasable, &1.id))
    |> Enum.map(&tombstone_device_preview(project_id, &1))
    |> Enum.count(&(&1 == :ok))
  end

  defp decoded_device_previews(project_id) do
    project_id
    |> Devices.list_delivery(:preview)
    |> Enum.flat_map(fn value ->
      case PreviewDeployment.from_value(value) do
        {:ok, deployment} -> [deployment]
        {:error, _reason} -> []
      end
    end)
  end

  # The same tombstone put every device rule above applies, through the same
  # helper. `to_value/1` round-trips the id and the state version the record was
  # read with unchanged, which is all the tombstone reads, so a record rewritten
  # since this sweep listed it is refused rather than overwritten and is judged
  # again on the next pass.
  defp tombstone_device_preview(project_id, %PreviewDeployment{} = record) do
    tombstone_device_delivery_record(project_id, :preview, PreviewDeployment.to_value(record))
  end

  # `"done"` and nothing else, stated once ahead of every status exactly as the
  # hosted `where` clause states it: `"none"` means the release was never asked
  # for rather than that nothing is owed, `"requested"` is a command made
  # durable that the provider never confirmed, and `"failed"` is a refusal. The
  # guard is about the remote, not about how the preview stopped.
  defp device_preview_due?(%PreviewDeployment{cleanup_state: "done"} = record, by_id, cutoff) do
    not PreviewDeployment.open?(record) and
      past_device_preview_window?(record, by_id, cutoff)
  end

  defp device_preview_due?(_unconfirmed_remote, _by_id, _cutoff), do: false

  defp past_device_preview_window?(record, by_id, cutoff) do
    case device_preview_stopped_at(record, by_id) do
      {:stopped_at, at} -> DateTime.compare(at, cutoff) != :gt
      :undatable -> false
    end
  end

  # What each terminal status can actually be dated by once it has crossed the
  # device seam. `PreviewDeployment.to_value/1` emits `requested_at`,
  # `ready_at`, `timeout_at`, and `expires_at` and no Ecto timestamp at all, so
  # neither the hosted rule's `COALESCE(expires_at, updated_at)` fallback nor
  # its `replacement.inserted_at` exists here, and nothing is invented to stand
  # in for them:
  #
  #   * `"expired"` — `expires_at`, the moment it stopped being reachable, the
  #     same instant the hosted rule prefers. A provider can report the status
  #     without ever stating a time, and `Previews` only invents one for a
  #     deployment it saw become ready, so such a record has no expiry and no
  #     last write to fall back to: it is `:undatable`.
  #   * `"timed_out"` — `timeout_at`, the deadline the request policy set and
  #     the value `Previews` compares against to declare the timeout, so the
  #     record is measured from when the preview stopped being useful rather
  #     than from when a later poll noticed. `from_value/1` refuses a record
  #     without one, so every decodable timed-out record carries it.
  #   * `"superseded"` — the *replacement* record's `requested_at`, found by id
  #     in the same listing. That is the device-visible instant of the write the
  #     hosted half measures as `inserted_at`: `Previews.start/4` writes
  #     `requested_at: now` on the replacement in the same atomic commit as the
  #     supersession link. This record's own `expires_at` is deliberately not
  #     consulted, for the reason the hosted rule states — it answers when this
  #     preview stopped being reachable, not when a later attempt made it the
  #     wrong one to look at. A replacement the store no longer holds leaves it
  #     `:undatable`, as the device evidence rule above decides the same case.
  #   * `"failed"` — `:undatable`. A provider refusal records no expiry, never
  #     became ready, and reached no deadline of its own, so `updated_at` was
  #     the only instant the hosted rule had for it and that is precisely what
  #     `to_value/1` does not carry. `requested_at` and `timeout_at` both belong
  #     to the request rather than to the refusal and can precede it by any
  #     amount, so measuring the window from either would release the record
  #     before the thirty days it is owed have run. Retaining a record whose
  #     remote is already confirmed torn down is the conservative side of that
  #     trade, and the one this seam takes.
  defp device_preview_stopped_at(
         %PreviewDeployment{status: "expired", expires_at: %DateTime{} = at},
         _by_id
       ),
       do: {:stopped_at, at}

  defp device_preview_stopped_at(
         %PreviewDeployment{status: "timed_out", timeout_at: %DateTime{} = at},
         _by_id
       ),
       do: {:stopped_at, at}

  defp device_preview_stopped_at(
         %PreviewDeployment{status: "superseded", superseded_by_id: replacement_id},
         by_id
       )
       when is_binary(replacement_id) do
    case Map.fetch(by_id, replacement_id) do
      {:ok, replacement} -> {:stopped_at, replacement.requested_at}
      :error -> :undatable
    end
  end

  defp device_preview_stopped_at(_undatable, _by_id), do: :undatable

  # The hosted rule holds back a due row that a *retained* row still names,
  # because `superseded_by_id` is `on_delete: :nilify_all` and clearing the link
  # of a row still marked `"superseded"` violates that table's pairing
  # constraint, aborting the whole pass. The device store has neither foreign
  # keys nor check constraints, so nothing here can abort — but the same removal
  # does real damage in its own way, so the hold-back is mirrored rather than
  # dropped. A retained record's supersession instant *is* its replacement's
  # `requested_at`, read out of this same listing, so tombstoning the
  # replacement first turns the record naming it `:undatable` permanently: the
  # moment its own provider cleanup is finally confirmed, the instant that would
  # have released it is gone and the sweep would retain it forever. That is
  # reachable exactly when the replacement's remote is settled and the
  # referrer's is not, which is an ordinary outcome rather than a corner case.
  #
  # The set is closed rather than filtered once, because holding one record back
  # makes it a retained referrer in its own right and a chain of supersessions
  # would otherwise strand its middle. Each pass drops at least one id, so the
  # recursion terminates.
  defp releasable_device_preview_ids(records, due) do
    strandable = MapSet.intersection(due, ids_named_by_retained_previews(records, due))

    if MapSet.size(strandable) == 0 do
      due
    else
      releasable_device_preview_ids(records, MapSet.difference(due, strandable))
    end
  end

  defp ids_named_by_retained_previews(records, due) do
    records
    |> Enum.reject(&MapSet.member?(due, &1.id))
    |> Enum.flat_map(&List.wrap(&1.superseded_by_id))
    |> MapSet.new()
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

  # The handoff's former identities are transient routing data. Acknowledgement
  # clears them immediately; this complementary rule bounds any links that remain
  # when a consumer is unavailable. It preserves the row and every reconciliation
  # field and is intentionally independent of acknowledgement state.
  defp prune_participation_revocation_links(now) do
    cutoff = DateTime.add(now, -@participation_window, :second)

    {count, _} =
      Repo.update_all(
        from(revocation in ParticipationRevocation,
          where:
            revocation.occurred_at <= ^cutoff and
              (not is_nil(revocation.former_hosted_identity_id) or
                 not is_nil(revocation.former_account_id))
        ),
        set: [former_hosted_identity_id: nil, former_account_id: nil, updated_at: now]
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

  # A plan abandoned before any build was ever started: no `Run` row names
  # this plan at all, so it is trivially never referenced by a `Result`
  # either. Mirrors `prune_onboarding_attempts/1`'s own 24-hour unconsumed
  # idiom above.
  defp prune_unstarted_repository_initialization_plans(now) do
    cutoff = DateTime.add(now, -@day, :second)

    {count, _} =
      Repo.delete_all(
        from plan in Plan,
          where:
            plan.updated_at <= ^cutoff and
              plan.id not in subquery(from run in Run, select: run.plan_id)
      )

    count
  end

  # A run left in a terminal failure/cancellation state, 24 hours after it
  # finished, is deleted together with its now-unreferenced plan — but only
  # when no `Result` exists for either the run or its plan. A `Result`
  # existing means initialization succeeded, so that plan/run pair is never a
  # candidate here regardless of `onboarding_handoff_state` (governed by
  # account erasure instead, per this module's own moduledoc). The second
  # `Result.plan_id` check is defensive: it should never trigger, since a
  # run's own idempotency key is deterministically derived from its plan id,
  # so a plan has at most one run in practice.
  defp repository_initialization_run_counts(now) do
    cutoff = DateTime.add(now, -@day, :second)

    due_runs =
      Repo.all(
        from run in Run,
          where: run.state in ["failed", "canceled"],
          where: fragment("COALESCE(?, ?)", run.finished_at, run.updated_at) <= ^cutoff,
          where: run.id not in subquery(from result in Result, select: result.run_id),
          select: %{id: run.id, plan_id: run.plan_id}
      )

    run_ids = Enum.map(due_runs, & &1.id)
    plan_ids = due_runs |> Enum.map(& &1.plan_id) |> Enum.uniq()

    {runs_deleted, _} = Repo.delete_all(from run in Run, where: run.id in ^run_ids)

    {plans_deleted, _} =
      Repo.delete_all(
        from plan in Plan,
          where:
            plan.id in ^plan_ids and
              plan.id not in subquery(from result in Result, select: result.plan_id)
      )

    %{
      expired_repository_initialization_runs: runs_deleted,
      expired_repository_initialization_orphan_plans: plans_deleted
    }
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
