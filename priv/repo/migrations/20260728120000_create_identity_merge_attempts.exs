defmodule SddOrchestrator.Repo.Migrations.CreateIdentityMergeAttempts do
  use Ecto.Migration

  @moduledoc """
  The transient orchestration record for one GitHub-to-passwordless identity
  merge: the matched candidate, the two-proof binding, and the commit marker.

  It holds no candidate email, project, repository, or secret. It links the
  absorbed (GitHub) and surviving (passwordless) accounts by id so the merge can
  lock and commit atomically, and expires in minutes so an unproven candidate
  never lingers. Detection writes the row (Task 4); the two fresh proofs and the
  confirmation are recorded against the same id (Task 5); commit stamps it
  (Task 6).
  """

  def change do
    create table(:identity_merge_attempts, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :absorbed_account_id,
          references(:accounts, type: :binary_id, on_delete: :delete_all),
          null: false

      add :surviving_account_id,
          references(:accounts, type: :binary_id, on_delete: :delete_all),
          null: false

      add :candidate_hosted_identity_id,
          references(:hosted_identities, type: :binary_id, on_delete: :delete_all),
          null: false

      add :status, :string, null: false, default: "detected"

      # The fresh GitHub authentication that started the attempt is recorded at
      # creation; the fresh passwordless proof and the explicit confirmation are
      # bound to this same attempt id before any commit.
      add :github_proven_at, :utc_datetime, null: false
      add :passwordless_proven_at, :utc_datetime
      add :passwordless_challenge_id, :binary_id
      add :confirmed_at, :utc_datetime
      add :committed_at, :utc_datetime

      add :expires_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:identity_merge_attempts, [:absorbed_account_id])
    create index(:identity_merge_attempts, [:surviving_account_id])
    create index(:identity_merge_attempts, [:expires_at])

    # At most one live (uncommitted, non-aborted) attempt per absorbed account, so
    # a retry reuses one transient candidate instead of accumulating parallel ones.
    create unique_index(:identity_merge_attempts, [:absorbed_account_id],
             name: :identity_merge_attempts_one_live_absorbed_index,
             where: "committed_at IS NULL AND status <> 'aborted'"
           )

    create constraint(:identity_merge_attempts, :identity_merge_attempts_status_check,
             check:
               "status IN ('detected', 'awaiting_confirmation', 'conflict', 'committed', 'aborted')"
           )
  end
end
