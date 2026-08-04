defmodule SddOrchestrator.Repo.Migrations.CreateAgentRuntimeObservations do
  use Ecto.Migration

  def up do
    create unique_index(:ai_runtime_sessions, [:account_id, :id],
             name: :ai_runtime_sessions_account_id_id_index
           )

    create table(:agent_runtime_observations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :session_id, :binary_id, null: false

      add :sequence, :bigint, null: false
      add :event_key, :string, null: false
      add :observed_at, :utc_datetime, null: false

      add :elapsed_seconds, :integer
      add :elapsed_source, :string, null: false

      add :input_tokens, :integer
      add :output_tokens, :integer
      add :total_tokens, :integer
      add :tokens_source, :string, null: false

      add :estimated_cost_amount, :decimal, precision: 12, scale: 4
      add :estimated_cost_currency, :string
      add :estimated_cost_basis, :map
      add :cost_source, :string, null: false

      add :quota_refs, :map, null: false, default: fragment("'{\"items\": []}'::jsonb")
      add :quota_source, :string, null: false

      add :status, :string, null: false
      add :status_source, :string, null: false
      add :pause_reason, :string

      add :unknown_fields, {:array, :string}, null: false, default: []

      timestamps(type: :utc_datetime)
    end

    # Ordering and idempotency are database invariants, not application habits.
    create unique_index(:agent_runtime_observations, [:session_id, :sequence],
             name: :agent_runtime_observations_session_sequence_index
           )

    create unique_index(:agent_runtime_observations, [:session_id, :event_key],
             name: :agent_runtime_observations_session_event_key_index
           )

    create index(:agent_runtime_observations, [:account_id, :session_id, :observed_at])

    execute(
      """
      ALTER TABLE agent_runtime_observations
      ADD CONSTRAINT agent_runtime_observations_account_session_fkey
      FOREIGN KEY (account_id, session_id)
      REFERENCES ai_runtime_sessions(account_id, id)
      ON DELETE CASCADE
      """,
      """
      ALTER TABLE agent_runtime_observations
      DROP CONSTRAINT IF EXISTS agent_runtime_observations_account_session_fkey
      """
    )

    create constraint(:agent_runtime_observations, :agent_runtime_observations_ordering_check,
             check: """
             sequence BETWEEN 1 AND 4294967295
             AND char_length(event_key) BETWEEN 1 AND 255
             AND btrim(event_key) = event_key
             """
           )

    # Every stored value carries one label from the same constrained vocabulary.
    # A label a value can never honestly carry is refused here rather than in
    # application code: elapsed time is never a provider fact, and an estimated
    # cost is never a provider invoice.
    create constraint(:agent_runtime_observations, :agent_runtime_observations_source_check,
             check: """
             elapsed_source IN ('worker_observed', 'unknown')
             AND tokens_source IN ('provider_fact', 'worker_observed', 'unknown')
             AND cost_source IN ('local_estimate', 'unknown')
             AND quota_source IN ('provider_fact', 'unknown')
             AND status_source IN ('provider_fact', 'worker_observed', 'unknown')
             """
           )

    create constraint(:agent_runtime_observations, :agent_runtime_observations_elapsed_check,
             check: """
             (elapsed_source = 'unknown' AND elapsed_seconds IS NULL)
             OR (elapsed_source <> 'unknown'
                 AND elapsed_seconds BETWEEN 0 AND 2592000)
             """
           )

    create constraint(:agent_runtime_observations, :agent_runtime_observations_tokens_check,
             check: """
             (tokens_source = 'unknown'
               AND input_tokens IS NULL
               AND output_tokens IS NULL
               AND total_tokens IS NULL)
             OR (tokens_source <> 'unknown'
                 AND total_tokens BETWEEN 0 AND 10000000
                 AND (input_tokens IS NULL OR input_tokens BETWEEN 0 AND 10000000)
                 AND (output_tokens IS NULL OR output_tokens BETWEEN 0 AND 10000000))
             """
           )

    # An estimate must identify its basis and cannot exist without the token
    # counts it was calculated from.
    create constraint(:agent_runtime_observations, :agent_runtime_observations_cost_check,
             check: """
             (cost_source = 'unknown'
               AND estimated_cost_amount IS NULL
               AND estimated_cost_currency IS NULL
               AND estimated_cost_basis IS NULL)
             OR (cost_source = 'local_estimate'
                 AND estimated_cost_amount IS NOT NULL
                 AND estimated_cost_amount >= 0
                 AND estimated_cost_currency ~ '^[A-Z]{3}$'
                 AND jsonb_typeof(estimated_cost_basis) = 'object'
                 AND tokens_source <> 'unknown')
             """
           )

    # Missing quota data is Unknown with no buckets. It is never stored as an
    # empty but known bucket set, which would read as unlimited or exhausted.
    create constraint(:agent_runtime_observations, :agent_runtime_observations_quota_check,
             check: """
             jsonb_typeof(quota_refs) = 'object'
             AND quota_refs ? 'items'
             AND jsonb_typeof(quota_refs->'items') = 'array'
             AND ((quota_source = 'unknown' AND jsonb_array_length(quota_refs->'items') = 0)
                  OR (quota_source = 'provider_fact'
                      AND jsonb_array_length(quota_refs->'items') > 0))
             """
           )

    # A paused agent carries a resumable reason and is never a terminal failure.
    create constraint(:agent_runtime_observations, :agent_runtime_observations_status_check,
             check: """
             status IN ('available', 'constrained', 'paused', 'unknown')
             AND (status = 'unknown') = (status_source = 'unknown')
             AND ((status = 'paused'
                   AND pause_reason IN ('quota_exhausted', 'spending_ceiling_reached'))
                  OR (status <> 'paused' AND pause_reason IS NULL))
             """
           )

    create constraint(:agent_runtime_observations, :agent_runtime_observations_unknowns_check,
             check: "cardinality(unknown_fields) <= 32"
           )
  end

  def down do
    drop table(:agent_runtime_observations)

    drop_if_exists index(:ai_runtime_sessions, [:account_id, :id],
                     name: :ai_runtime_sessions_account_id_id_index
                   )
  end
end
