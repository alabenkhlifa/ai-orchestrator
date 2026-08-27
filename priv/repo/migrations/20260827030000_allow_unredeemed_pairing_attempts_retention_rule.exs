defmodule SddOrchestrator.Repo.Migrations.AllowUnredeemedPairingAttemptsRetentionRule do
  use Ecto.Migration

  # specs/38 Task 7: a pairing attempt nobody redeemed gains its own expiry
  # rule, so `retention_rule_outcomes` must be able to name it.
  #
  # The rule vocabulary is closed in three places at once — `Retention.rules/0`,
  # `RetentionRuleOutcome`'s `@rules`, and this check constraint — so a rule
  # added to only some of them fails loudly instead of silently landing in
  # `Retention`'s `log_unrecorded/1` branch with no durable outcome. This
  # migration is the third.
  #
  # A check constraint cannot be widened in place, so both directions drop and
  # recreate it, and the two lists are written out separately so `down` is a
  # real inverse rather than one derived from the other.

  @added_rule "unredeemed_pairing_attempts"

  @rules_before ~w(
    acknowledged_personal_ai_connections
    ai_runtime_observations
    ai_runtime_sessions
    ai_runtime_snapshots
    authorization_attempts
    departed_participant_links
    device_import_attempts
    device_project_assistant_conversations
    expired_delivery_artifacts
    expired_delivery_checkpoints
    expired_delivery_commands
    expired_delivery_notifications
    expired_delivery_previews
    expired_delivery_security_events
    expired_device_delivery_artifacts
    expired_device_delivery_checkpoints
    expired_device_delivery_commands
    expired_device_delivery_previews
    expired_invitations
    expired_participation_email_delivery_diagnostics
    expired_participation_notifications
    expired_participation_security_events
    hosted_import_attempts
    hosted_sessions
    magic_link_attempts
    merge_records
    onboarding_attempts
    participation_revocation_links
    project_assistant_conversations
    released_delivery_attempt_leases
    repository_initialization_runs
    retention_rule_outcomes
    revoked_personal_ai_connections
    sessions
    terminal_invitations
    unstarted_repository_initialization_plans
  )

  @rules_after Enum.sort([@added_rule | @rules_before])

  def up do
    replace_rule_constraint(@rules_after)
  end

  # Reversible only while no row names the rule being removed. The retention
  # pass rewrites its own rows every pass, so such a row is deleted rather than
  # left to fail the recreated constraint. This is operational rule state, never
  # personal data.
  def down do
    execute("DELETE FROM retention_rule_outcomes WHERE rule = '#{@added_rule}'")

    replace_rule_constraint(@rules_before)
  end

  defp replace_rule_constraint(rules) do
    drop constraint(:retention_rule_outcomes, :retention_rule_outcomes_rule_allowed)

    create constraint(
             :retention_rule_outcomes,
             :retention_rule_outcomes_rule_allowed,
             check: "rule IN (#{quoted(rules)})"
           )
  end

  defp quoted(values), do: Enum.map_join(values, ", ", &"'#{&1}'")
end
