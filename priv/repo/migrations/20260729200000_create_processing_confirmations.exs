defmodule SddOrchestrator.Repo.Migrations.CreateProcessingConfirmations do
  use Ecto.Migration

  def change do
    create table(:processing_confirmations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      # The digest is what the person actually agreed to. Storing it rather than
      # a boolean is what lets a later configuration change invalidate the
      # confirmation instead of silently inheriting it.
      add :disclosure_version, :integer, null: false
      add :disclosure_digest, :string, null: false
      add :confirmed_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    # One confirmation per person per project: a new boundary replaces the old
    # agreement rather than accumulating a history of them.
    create unique_index(:processing_confirmations, [:project_id, :account_id])

    create constraint(
             :processing_confirmations,
             :processing_confirmations_version_positive,
             check: "disclosure_version > 0"
           )
  end
end
