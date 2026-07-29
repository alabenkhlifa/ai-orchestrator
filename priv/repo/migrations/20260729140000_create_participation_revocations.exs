defmodule SddOrchestrator.Repo.Migrations.CreateParticipationRevocations do
  use Ecto.Migration

  def change do
    create table(:participation_revocations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :contract_version, :integer, null: false, default: 1

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :project_participant_id,
          references(:project_participants, type: :binary_id, on_delete: :delete_all),
          null: false

      add :former_hosted_identity_id,
          references(:hosted_identities, type: :binary_id, on_delete: :nilify_all)

      add :former_account_id, references(:accounts, type: :binary_id, on_delete: :nilify_all)

      add :owner_account_id, references(:accounts, type: :binary_id, on_delete: :nilify_all),
        null: false

      add :last_display_name, :string
      add :reason, :string, null: false
      add :occurred_at, :utc_datetime, null: false
      add :claimed_at, :utc_datetime
      add :acknowledged_at, :utc_datetime
      add :consumer_ref, :string

      timestamps(type: :utc_datetime)
    end

    # One handoff per departure. A person who rejoins and leaves again departs a
    # different participation row and therefore produces a distinct handoff.
    create unique_index(:participation_revocations, [:project_participant_id],
             name: :participation_revocations_participation_index
           )

    create index(:participation_revocations, [:project_id])
    create index(:participation_revocations, [:acknowledged_at, :occurred_at])

    create constraint(:participation_revocations, :participation_revocations_reason_allowed,
             check: "reason IN ('removed', 'left')"
           )

    create constraint(
             :participation_revocations,
             :participation_revocations_contract_version_positive,
             check: "contract_version > 0"
           )

    create constraint(:participation_revocations, :participation_revocations_ack_shape,
             check: "acknowledged_at IS NULL OR claimed_at IS NOT NULL"
           )
  end
end
