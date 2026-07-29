defmodule SddOrchestrator.Repo.Migrations.CreateProjectParticipation do
  use Ecto.Migration

  def change do
    create table(:project_participants, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :hosted_identity_id,
          references(:hosted_identities, type: :binary_id, on_delete: :nilify_all)

      add :role, :string, null: false, default: "participant"
      add :state, :string, null: false, default: "active"
      add :joined_at, :utc_datetime, null: false
      add :departed_at, :utc_datetime
      add :departure_reason, :string

      timestamps(type: :utc_datetime)
    end

    create index(:project_participants, [:project_id])
    create index(:project_participants, [:hosted_identity_id])

    create unique_index(:project_participants, [:project_id, :hosted_identity_id],
             where: "state = 'active'",
             name: :project_participants_active_identity_index
           )

    create constraint(:project_participants, :project_participants_role_allowed,
             check: "role IN ('participant')"
           )

    create constraint(:project_participants, :project_participants_state_allowed,
             check: "state IN ('active', 'departed')"
           )

    create constraint(:project_participants, :project_participants_departure_reason_allowed,
             check: "departure_reason IS NULL OR departure_reason IN ('removed', 'left')"
           )

    # An active authorization always names its stable hosted identity and has no
    # departure. A departed row records when and why it ended, and its identity
    # link may be erased later by the approved retention rule.
    create constraint(:project_participants, :project_participants_state_shape,
             check: """
             (state = 'active' AND hosted_identity_id IS NOT NULL AND departed_at IS NULL
               AND departure_reason IS NULL)
             OR (state = 'departed' AND departed_at IS NOT NULL AND departure_reason IS NOT NULL)
             """
           )

    create table(:project_member_profiles, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :account_id, references(:accounts, type: :binary_id, on_delete: :nilify_all)

      add :role, :string, null: false
      add :state, :string, null: false, default: "active"
      add :display_name, :string, null: false
      add :display_name_key, :string, null: false
      add :anonymized_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:project_member_profiles, [:project_id])

    # One presentation label per project while the member is current. A departed
    # label is preserved for historical attribution without reserving the name.
    create unique_index(:project_member_profiles, [:project_id, :display_name_key],
             where: "state = 'active'",
             name: :project_member_profiles_active_display_name_index
           )

    create unique_index(:project_member_profiles, [:project_id, :account_id],
             where: "account_id IS NOT NULL",
             name: :project_member_profiles_account_index
           )

    create constraint(:project_member_profiles, :project_member_profiles_role_allowed,
             check: "role IN ('owner', 'participant')"
           )

    create constraint(:project_member_profiles, :project_member_profiles_state_allowed,
             check: "state IN ('active', 'historical', 'anonymized')"
           )

    # Anonymization removes the account link and keeps only the anonymous label.
    create constraint(:project_member_profiles, :project_member_profiles_anonymized_shape,
             check: """
             (state = 'anonymized' AND account_id IS NULL AND anonymized_at IS NOT NULL)
             OR (state <> 'anonymized' AND anonymized_at IS NULL)
             """
           )
  end
end
