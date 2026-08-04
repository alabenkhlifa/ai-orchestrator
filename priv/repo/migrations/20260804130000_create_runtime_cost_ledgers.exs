defmodule SddOrchestrator.Repo.Migrations.CreateRuntimeCostLedgers do
  use Ecto.Migration

  def up do
    create table(:runtime_cost_ledgers, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :session_id,
          references(:ai_runtime_sessions, type: :binary_id, on_delete: :delete_all),
          null: false

      add :currency, :string, null: false
      add :ceiling, :decimal, precision: 12, scale: 4, null: false
      add :price_version, :string, null: false
      add :price_source, :string, null: false
      add :price_published_at, :utc_datetime, null: false
      add :price_expires_at, :utc_datetime, null: false
      add :input_unit_price, :decimal, precision: 18, scale: 8, null: false
      add :output_unit_price, :decimal, precision: 18, scale: 8, null: false
      add :max_input_tokens, :integer, null: false
      add :max_output_tokens, :integer, null: false
      add :reserved_amount, :decimal, precision: 12, scale: 4, null: false, default: 0
      add :observed_amount, :decimal, precision: 12, scale: 4, null: false, default: 0

      add :outstanding_reservations, :map,
        null: false,
        default: fragment("'{}'::jsonb")

      add :paused, :boolean, null: false, default: false
      add :pause_reason, :string
      add :paused_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:runtime_cost_ledgers, [:session_id],
             name: :runtime_cost_ledgers_session_index
           )

    create index(:runtime_cost_ledgers, [:account_id])

    create constraint(:runtime_cost_ledgers, :runtime_cost_ledgers_currency_check,
             check: "currency ~ '^[A-Z]{3}$'"
           )

    create constraint(:runtime_cost_ledgers, :runtime_cost_ledgers_ceiling_check,
             check: "ceiling > 0 AND ceiling <= 1000000"
           )

    create constraint(:runtime_cost_ledgers, :runtime_cost_ledgers_price_check,
             check: """
             char_length(price_version) BETWEEN 1 AND 100
             AND char_length(price_source) BETWEEN 1 AND 100
             AND price_expires_at > price_published_at
             AND input_unit_price > 0
             AND output_unit_price > 0
             """
           )

    create constraint(:runtime_cost_ledgers, :runtime_cost_ledgers_bounded_request_check,
             check: """
             max_input_tokens BETWEEN 1 AND 10000000
             AND max_output_tokens BETWEEN 1 AND 10000000
             """
           )

    create constraint(:runtime_cost_ledgers, :runtime_cost_ledgers_capacity_check,
             check: """
             reserved_amount >= 0
             AND observed_amount >= 0
             AND reserved_amount + observed_amount <= ceiling
             """
           )

    create constraint(:runtime_cost_ledgers, :runtime_cost_ledgers_reservations_check,
             check: "jsonb_typeof(outstanding_reservations) = 'object'"
           )

    create constraint(:runtime_cost_ledgers, :runtime_cost_ledgers_pause_check,
             check: """
             (paused
               AND pause_reason IN ('insufficient_capacity')
               AND paused_at IS NOT NULL)
             OR (NOT paused AND pause_reason IS NULL AND paused_at IS NULL)
             """
           )
  end

  def down do
    drop table(:runtime_cost_ledgers)
  end
end
