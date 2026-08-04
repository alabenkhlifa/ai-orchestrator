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

  Encrypted GitHub credentials and confirmed project metadata are kept while the
  account or project requires them and are removed by account erasure, not by time.
  Operational-security log and backup retention (30 and 35 days) are enforced by the
  deployment's log and backup infrastructure, recorded in the deployment privacy
  profile. These deletes are idempotent, so re-running the pruner is safe.
  """
  import Ecto.Query

  alias SddOrchestrator.Accounts.{ApplicationSession, GitHubAuthorizationAttempt}
  alias SddOrchestrator.Accounts.{HostedSession, MagicLinkAttempt}
  alias SddOrchestrator.AIRuntime.{PersonalAIConnection, PersonalConnectionRevocations}
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
