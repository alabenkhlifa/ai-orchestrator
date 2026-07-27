defmodule SddOrchestrator.Repo.Migrations.CreateHostedIdentityFoundation do
  use Ecto.Migration

  def change do
    create table(:hosted_identities, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:hosted_identities, [:account_id])

    create table(:external_identities, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :provider, :string, null: false
      add :subject_key, :string, null: false
      add :display_identifier, :string, null: false
      add :verified_at, :utc_datetime, null: false

      add :hosted_identity_id,
          references(:hosted_identities, type: :binary_id, on_delete: :delete_all),
          null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:external_identities, [:provider, :subject_key],
             name: :external_identities_provider_subject_key_index
           )

    create unique_index(:external_identities, [:hosted_identity_id, :provider],
             name: :external_identities_hosted_identity_provider_index
           )
  end
end
