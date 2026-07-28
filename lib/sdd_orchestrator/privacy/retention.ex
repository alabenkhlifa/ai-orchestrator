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

  Encrypted GitHub credentials and confirmed project metadata are kept while the
  account or project requires them and are removed by account erasure, not by time.
  Operational-security log and backup retention (30 and 35 days) are enforced by the
  deployment's log and backup infrastructure, recorded in the deployment privacy
  profile. These deletes are idempotent, so re-running the pruner is safe.
  """
  import Ecto.Query

  alias SddOrchestrator.Accounts.{ApplicationSession, GitHubAuthorizationAttempt}
  alias SddOrchestrator.Accounts.{HostedSession, MagicLinkAttempt}
  alias SddOrchestrator.Devices
  alias SddOrchestrator.IdentityLinking
  alias SddOrchestrator.Portability.ImportAttempt
  alias SddOrchestrator.Projects.ProjectOnboardingAttempt
  alias SddOrchestrator.Repo

  @day 24 * 60 * 60

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
      merge_records: IdentityLinking.prune_merge_records(now)
    }
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
