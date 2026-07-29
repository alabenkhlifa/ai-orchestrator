defmodule SddOrchestrator.Repo.Migrations.CreateFeatures do
  use Ecto.Migration

  def change do
    create table(:features, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :title, :string, null: false

      add :creator_account_id, references(:accounts, type: :binary_id, on_delete: :nilify_all),
        null: false

      add :assigned_account_id, references(:accounts, type: :binary_id, on_delete: :nilify_all)

      add :lifecycle_column, :string, null: false, default: "draft"
      add :status, :string, null: false, default: "none"
      add :state_version, :integer, null: false, default: 1

      timestamps(type: :utc_datetime)
    end

    create index(:features, [:project_id, :lifecycle_column])
    create index(:features, [:assigned_account_id])

    create constraint(:features, :features_lifecycle_column_allowed,
             check: """
             lifecycle_column IN
               ('draft', 'ready_for_development', 'in_development', 'ready_for_review', 'done')
             """
           )

    create constraint(:features, :features_status_allowed,
             check: "status IN ('none', 'blocked', 'failed')"
           )

    create constraint(:features, :features_state_version_positive, check: "state_version > 0")

    # `Blocked` and `Failed` are statuses, never columns: a feature can only carry
    # one while it sits in `In development`.
    create constraint(:features, :features_status_placement,
             check: "status = 'none' OR lifecycle_column = 'in_development'"
           )
  end
end
