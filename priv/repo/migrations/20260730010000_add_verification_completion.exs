defmodule SddOrchestrator.Repo.Migrations.AddVerificationCompletion do
  use Ecto.Migration

  # The activity vocabulary before and after this change. A verified completion
  # and a refused one are different facts, so they are different types: a reader
  # scanning the history must not have to open a payload to tell "the checks
  # proved this commit" from "a worker said so and could not prove it".
  @types_before """
  type IN
    ('assignment_changed', 'comment', 'evidence_recorded', 'preview_updated',
     'progress', 'question_answered', 'question_asked', 'readiness_evaluated',
     'reconciled', 'retry_scheduled', 'review_approved', 'review_rejected',
     'revocation_applied', 'run_canceled', 'run_completed', 'run_failed',
     'run_started', 'suggestion_dismissed')
  """

  @types_after """
  type IN
    ('assignment_changed', 'comment', 'evidence_recorded', 'preview_updated',
     'progress', 'question_answered', 'question_asked', 'readiness_evaluated',
     'reconciled', 'retry_scheduled', 'review_approved', 'review_rejected',
     'revocation_applied', 'run_canceled', 'run_completed', 'run_failed',
     'run_started', 'suggestion_dismissed', 'verification_completed',
     'verification_refused')
  """

  def up do
    # The attempt already records which manifest bound it, but a digest cannot
    # be read. The required-check contract that manifest carried is snapshotted
    # here so the completion gate can name what was actually required, without
    # re-reading a configuration that may have changed since the attempt began.
    #
    # The default is an empty array rather than a set of checks, and an empty
    # contract is deliberately not "nothing was required": the gate refuses a
    # completion claim it cannot check. A default that read as "all required
    # checks passed" would be the false success this whole path exists to stop.
    alter table(:run_attempts) do
      add :required_checks, :jsonb, null: false, default: fragment("'[]'::jsonb")
    end

    create constraint(:run_attempts, :run_attempts_required_checks_array,
             check: "jsonb_typeof(required_checks) = 'array'"
           )

    drop constraint(:activity_entries, :activity_entries_type_allowed)

    create constraint(:activity_entries, :activity_entries_type_allowed, check: @types_after)
  end

  def down do
    drop constraint(:activity_entries, :activity_entries_type_allowed)

    create constraint(:activity_entries, :activity_entries_type_allowed, check: @types_before)

    drop constraint(:run_attempts, :run_attempts_required_checks_array)

    alter table(:run_attempts) do
      remove :required_checks
    end
  end
end
