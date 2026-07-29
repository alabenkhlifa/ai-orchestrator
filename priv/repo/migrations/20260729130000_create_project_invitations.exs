defmodule SddOrchestrator.Repo.Migrations.CreateProjectInvitations do
  use Ecto.Migration

  def change do
    create table(:project_invitations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :invited_by_account_id, references(:accounts, type: :binary_id, on_delete: :nilify_all)

      add :email_digest, :binary, null: false
      add :delivery_email, :binary, null: false
      add :token_digest, :binary
      add :token_salt, :binary
      add :status, :string, null: false, default: "pending"
      add :expires_at, :utc_datetime, null: false
      add :terminal_at, :utc_datetime
      add :terminal_reason, :string
      add :credential_version, :integer, null: false, default: 1

      timestamps(type: :utc_datetime)
    end

    create index(:project_invitations, [:project_id])
    create index(:project_invitations, [:status, :expires_at])

    # At most one pending invitation per project and normalized email. A terminal
    # invitation is history and never blocks a fresh invitation.
    create unique_index(:project_invitations, [:project_id, :email_digest],
             where: "status = 'pending'",
             name: :project_invitations_pending_email_index
           )

    create constraint(:project_invitations, :project_invitations_status_allowed,
             check: "status IN ('pending', 'accepted', 'declined', 'canceled', 'expired')"
           )

    create constraint(:project_invitations, :project_invitations_credential_version_positive,
             check: "credential_version > 0"
           )

    # A pending invitation always holds its credential material; every terminal
    # transition erases it immediately and records when and why it ended.
    create constraint(:project_invitations, :project_invitations_credential_shape,
             check: """
             (status = 'pending' AND token_digest IS NOT NULL AND token_salt IS NOT NULL
               AND terminal_at IS NULL AND terminal_reason IS NULL)
             OR (status <> 'pending' AND token_digest IS NULL AND token_salt IS NULL
               AND terminal_at IS NOT NULL AND terminal_reason IS NOT NULL)
             """
           )
  end
end
