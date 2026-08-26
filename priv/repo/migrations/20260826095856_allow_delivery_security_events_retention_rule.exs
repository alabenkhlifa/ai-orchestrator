defmodule SddOrchestrator.Repo.Migrations.AllowDeliverySecurityEventsRetentionRule do
  use Ecto.Migration

  # specs/19 Task 5: the guided-delivery operational-security log gains its own
  # 30-day expiry rule, so `retention_rule_outcomes` must be able to name it.
  #
  # The rule vocabulary is deliberately closed in three places at once —
  # `SddOrchestrator.Privacy.Retention.rules/0` (execution order and
  # advisory-lock key), `SddOrchestrator.Privacy.RetentionRuleOutcome`'s
  # `@rules` (the `Ecto.Enum`), and this check constraint — so that a rule
  # added to only some of them fails loudly rather than silently landing in
  # `Retention`'s `log_unrecorded/1` branch and leaving the rule with no
  # durable outcome at all. Adding a rule therefore means all three, in one
  # change; this migration is the third.
  #
  # A check constraint cannot be widened in place, so both directions drop and
  # recreate it. `down` is a real inverse: it restores the exact pre-Task-5
  # vocabulary, which is why the two lists are written out separately rather
  # than one being derived from the other.

  @added_rule "expired_delivery_security_events"

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

  # Reversible only while no row names the rule being removed. A row that does
  # is the outcome of a rule that no longer exists in this direction, and the
  # retention pass rewrites its own rows every pass, so it is deleted rather
  # than allowed to fail the recreated constraint. No other row, and no other
  # table, is touched: this is operational rule state, never personal data.
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
