defmodule SddOrchestrator.Privacy.RetentionRuleOutcome do
  @moduledoc """
  The durable outcome of one retention rule's last pass (specs/19 Task 3).

  `SddOrchestrator.Privacy.Retention.prune_all/1` reports how many rows each
  rule deleted and then forgets it. That number answers "what did this pass
  do"; it cannot answer "did this rule run at all", "has it been failing since
  Tuesday", or "which authority was unreachable when it stopped working" —
  and a rule that fails or is interrupted stays invisible until somebody
  notices data sitting past its own limit. One row per rule, rewritten every
  pass, is what makes that answerable across a restart.

  ## Operational, and structurally incapable of holding what the rules delete

  This is the one record in the retention path whose failure branch could
  accidentally preserve exactly the data the rules exist to remove: the
  natural thing to store beside a failure is "which rows", "how many", and
  "what went wrong", and all three are the personal data or a direct pointer
  at it. So the guarantee is made by the schema rather than by discipline at
  the call site — the table declares no column that could carry:

    * any project, participant, account, workspace, device, worker, feature,
      run, attempt, or artifact identifier. There is no foreign key here at
      all, and `rule` is a closed `Ecto.Enum` over
      `SddOrchestrator.Privacy.Retention`'s own fixed rule vocabulary, so the
      only thing this row names is a rule;
    * any count or identifier of the rows a rule touched. Row counts stay in
      `prune_all/1`'s returned map, which is per-pass and in memory; this row
      records whether the rule completed, never what it reached;
    * any error message, exception, stack trace, query, or provider payload.
      `failure_class` is a closed four-value `Ecto.Enum` — the coarse
      difference between an unreachable device store, an unavailable
      database, a constraint the rule violated, and anything else — with no
      free-text sibling to hold the detail it drops.

  `correlation_id` is a fresh `Ecto.UUID.generate/0` value minted once per
  pass and never derived from anything, exactly as
  `SddOrchestrator.Privacy.ParticipationSecurityLog`'s own identifier is: it
  groups the rules of one pass and cannot be used to recognise the same
  project, account, or device across passes, because two passes over the same
  data always get different identifiers.

  ## State vocabulary

  Mirrors `SddOrchestrator.Privacy.ParticipationCleanupRequest`'s closed
  acknowledgement/attempt shape, the repository's existing precedent for
  durable, retryable, reconcilable per-item state:

    * `:succeeded` — the rule ran to completion in that pass. `succeeded_at`
      is set and `failure_class` is null.
    * `:retry_pending` — the rule could not complete for a reason outside
      itself (an unreachable device store, an unavailable database). The next
      pass simply runs it again.
    * `:failed` — the rule itself did not work (it violated a constraint, or
      raised something unclassified). The next pass runs it again too; the
      distinction is for whoever is reading the row, not for the retry.

  Retry needs no stored work list, because every retention selector is a pure
  function of authoritative state and `now`: "retrying" a rule is running it
  again, and the row is only what makes the earlier failure visible.

  `succeeded_at` is the last pass this rule actually completed, and is
  deliberately *not* cleared by a later failure — "last worked at" is the
  question an operator asks about a rule that is failing now. `attempt_count`
  counts passes that attempted the rule, so it advances on success and on
  failure alike.
  """
  use Ecto.Schema

  import Ecto.Changeset

  # The closed rule vocabulary. `SddOrchestrator.Privacy.Retention` owns the
  # execution order and the per-rule advisory-lock key; this list owns the
  # names, sorted so the two cannot silently drift into "whatever order the
  # runner happens to use". Retention's own proof asserts the two agree.
  #
  # The `retention_rule_outcomes_rule_allowed` check constraint holds the same
  # names a third time, so a rule added to `rules/0` alone fails loudly here
  # (an invalid `Ecto.Enum` cast) rather than silently reaching
  # `Retention`'s `log_unrecorded/1` branch, and one added here alone fails
  # loudly at the constraint. Adding a rule means all three, in one change.
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
    unredeemed_pairing_attempts
    unstarted_repository_initialization_plans
  )a

  @states ~w(succeeded failed retry_pending)a

  # Coarse categories, never a message and never an exception. Each one
  # answers a different operational question: whose authority was missing, or
  # whether the rule itself is broken.
  @failure_classes ~w(
    store_unavailable
    database_unavailable
    constraint_violation
    unexpected_error
  )a

  # An authority that was simply not there is retried on the next pass and
  # is expected to clear itself; a rule that violated a constraint or raised
  # something unclassified is a defect and is flagged as one. Both are run
  # again next pass — the split is what an operator reads, not a schedule.
  @retryable_failure_classes ~w(store_unavailable database_unavailable)a

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  @type t :: %__MODULE__{}

  schema "retention_rule_outcomes" do
    field :rule, Ecto.Enum, values: @rules
    field :state, Ecto.Enum, values: @states
    field :failure_class, Ecto.Enum, values: @failure_classes
    field :attempt_count, :integer, default: 0
    field :last_attempted_at, :utc_datetime
    field :succeeded_at, :utc_datetime
    field :correlation_id, Ecto.UUID

    timestamps()
  end

  @doc "The closed retention-rule vocabulary a row may name, sorted."
  @spec rules() :: [atom()]
  def rules, do: @rules

  @doc "The closed outcome-state vocabulary."
  @spec states() :: [atom()]
  def states, do: @states

  @doc "The closed coarse failure-class vocabulary. Never a message or an exception."
  @spec failure_classes() :: [atom()]
  def failure_classes, do: @failure_classes

  @doc """
  Classifies one coarse failure class into the state it records.

  An unreachable store or database is `:retry_pending`; anything else is
  `:failed`. Both are retried on the next pass — see this module's moduledoc.
  """
  @spec state_for_failure(atom()) :: :retry_pending | :failed
  def state_for_failure(failure_class) when failure_class in @retryable_failure_classes,
    do: :retry_pending

  def state_for_failure(failure_class) when failure_class in @failure_classes, do: :failed

  @doc """
  Records a pass in which the rule ran to completion.

  Clears any prior `failure_class`, since a failure classification has no
  purpose once the same rule later completes, and advances `succeeded_at` to
  this pass. Mirrors `ParticipationCleanupRequest.acknowledge_changeset/2`.
  """
  @spec succeeded_changeset(t(), map()) :: Ecto.Changeset.t()
  def succeeded_changeset(%__MODULE__{} = outcome, attrs) do
    outcome
    |> cast(attrs, [:rule, :last_attempted_at, :correlation_id])
    |> put_change(:state, :succeeded)
    |> put_change(:failure_class, nil)
    |> put_attempt_count(outcome)
    |> put_succeeded_at()
    |> validate_required([:rule, :last_attempted_at, :succeeded_at, :correlation_id])
    |> apply_shared_constraints()
  end

  @doc """
  Records a pass in which the rule did not complete, under one coarse class.

  The class is the only thing kept about the failure. `succeeded_at` is never
  cleared here: a rule that is failing now still has a last-worked-at, and
  that is the more useful of the two facts.
  """
  @spec failed_changeset(t(), map()) :: Ecto.Changeset.t()
  def failed_changeset(%__MODULE__{} = outcome, attrs) do
    outcome
    |> cast(attrs, [:rule, :state, :failure_class, :last_attempted_at, :correlation_id])
    |> put_attempt_count(outcome)
    |> validate_required([:rule, :state, :failure_class, :last_attempted_at, :correlation_id])
    |> validate_inclusion(:state, [:failed, :retry_pending])
    |> validate_inclusion(:failure_class, @failure_classes)
    |> apply_shared_constraints()
  end

  defp put_attempt_count(changeset, %__MODULE__{attempt_count: count}) do
    put_change(changeset, :attempt_count, (count || 0) + 1)
  end

  defp put_succeeded_at(changeset) do
    put_change(changeset, :succeeded_at, get_field(changeset, :last_attempted_at))
  end

  defp apply_shared_constraints(changeset) do
    changeset
    |> validate_inclusion(:rule, @rules)
    |> validate_number(:attempt_count, greater_than: 0)
    |> unique_constraint(:rule, name: :retention_rule_outcomes_rule_index)
    |> check_constraint(:rule, name: :retention_rule_outcomes_rule_allowed)
    |> check_constraint(:state, name: :retention_rule_outcomes_state_allowed)
    |> check_constraint(:failure_class, name: :retention_rule_outcomes_failure_class_allowed)
    |> check_constraint(:failure_class, name: :retention_rule_outcomes_failure_pairing)
    |> check_constraint(:succeeded_at, name: :retention_rule_outcomes_success_pairing)
  end
end
