defmodule SddOrchestrator.Repo.Migrations.CreateRetentionRuleOutcomes do
  use Ecto.Migration

  # specs/19 Task 3: one durable row per retention rule, carrying the outcome
  # of that rule's last pass so a failed or interrupted rule is visible before
  # somebody notices data sitting past its own limit.
  #
  # This table is operational and holds no personal data, and the schema is
  # what enforces that rather than the call site. There is no foreign key
  # here at all — no project, participant, account, workspace, device,
  # worker, feature, run, attempt, or artifact column exists to hold one —
  # no column carrying how many rows or which rows a rule touched (row counts
  # stay in `Retention.prune_all/1`'s in-memory returned map), and no free
  # text of any kind: `failure_class` is a closed four-value classification,
  # so an error message, exception, stack trace, query, or provider payload
  # has nowhere to land. `correlation_id` is a fresh per-pass UUID, never
  # derived from any of the above, matching
  # `participation_security_events.correlation_id`.
  @rules ~w(
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

  @states ~w(succeeded failed retry_pending)

  @failure_classes ~w(
    store_unavailable
    database_unavailable
    constraint_violation
    unexpected_error
  )

  def change do
    create table(:retention_rule_outcomes, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # The only thing this row names. A closed vocabulary in the database as
      # well as in the schema, so the column cannot become a place to write
      # an identifier or a note.
      add :rule, :string, null: false

      add :state, :string, null: false
      add :failure_class, :string
      add :attempt_count, :integer, null: false, default: 0

      add :last_attempted_at, :utc_datetime, null: false
      add :succeeded_at, :utc_datetime

      # Fresh per pass, never derived from anything.
      add :correlation_id, :uuid, null: false

      timestamps(type: :utc_datetime)
    end

    # Exactly one row per rule: the record is the rule's current outcome, not
    # a history of every pass, so a hundred passes leave one row rather than a
    # growing operational log.
    create unique_index(:retention_rule_outcomes, [:rule],
             name: :retention_rule_outcomes_rule_index
           )

    # The self-pruning rule selects succeeded rows past the 30-day boundary.
    create index(:retention_rule_outcomes, [:state, :succeeded_at])

    create constraint(
             :retention_rule_outcomes,
             :retention_rule_outcomes_rule_allowed,
             check: "rule IN (#{quoted(@rules)})"
           )

    create constraint(
             :retention_rule_outcomes,
             :retention_rule_outcomes_state_allowed,
             check: "state IN (#{quoted(@states)})"
           )

    create constraint(
             :retention_rule_outcomes,
             :retention_rule_outcomes_failure_class_allowed,
             check: "failure_class IS NULL OR failure_class IN (#{quoted(@failure_classes)})"
           )

    # State pairing the row itself enforces rather than a caller convention,
    # mirroring `participation_cleanup_requests_retry_pairing`: a completed
    # rule carries no classification, and an incomplete one always does.
    create constraint(
             :retention_rule_outcomes,
             :retention_rule_outcomes_failure_pairing,
             check: "(failure_class IS NOT NULL) = (state IN ('failed', 'retry_pending'))"
           )

    # A succeeded row always records when. The reverse is deliberately not
    # constrained: `succeeded_at` survives a later failure, because "last
    # worked at" is the question asked about a rule that is failing now.
    create constraint(
             :retention_rule_outcomes,
             :retention_rule_outcomes_success_pairing,
             check: "state <> 'succeeded' OR succeeded_at IS NOT NULL"
           )
  end

  defp quoted(values), do: Enum.map_join(values, ", ", &"'#{&1}'")
end
