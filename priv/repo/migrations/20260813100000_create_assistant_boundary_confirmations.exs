defmodule SddOrchestrator.Repo.Migrations.CreateAssistantBoundaryConfirmations do
  use Ecto.Migration

  def change do
    create table(:assistant_boundary_confirmations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      # The same stable participant identity `project_assistant_conversations`
      # keys on: an account rather than a hosted identity, so a departed-then-
      # reinvited participant's confirmation still tracks the same private
      # boundary owner.
      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      # The stable hash of the disclosed processing summary (execution
      # location, provider, repository-worker availability, transfer,
      # storage, and retention boundary) the participant confirmed. No
      # credential, exact quota, or provider diagnostic is ever part of this
      # digest's input.
      add :boundary_digest, :string, null: false

      add :boundary_version, :integer, null: false
      add :confirmed_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    # One current confirmation per participant per project. A material
    # boundary change does not delete this row; the stored digest simply
    # stops matching the freshly built one, which the pre-tool gate reads as
    # invalidated without a separate stored state to drift out of sync.
    create unique_index(:assistant_boundary_confirmations, [:project_id, :account_id])

    create constraint(
             :assistant_boundary_confirmations,
             :assistant_boundary_confirmations_boundary_version_positive,
             check: "boundary_version > 0"
           )
  end
end
