defmodule SddOrchestrator.Repo.Migrations.AddMergePasswordlessProof do
  use Ecto.Migration

  @moduledoc """
  Adds the self-contained passwordless-proof challenge bound to one merge attempt.

  The raw token is never stored; only its salted SHA-256 digest and salt are kept,
  mirroring the passwordless magic-link contract, and both are cleared once the
  proof succeeds so the challenge is single-use. The public challenge reference
  (`passwordless_challenge_id`, added with the attempt) locates the attempt from
  the emailed link without exposing the internal attempt id.
  """

  def change do
    alter table(:identity_merge_attempts) do
      add :passwordless_proof_digest, :binary
      add :passwordless_proof_salt, :binary
      add :passwordless_proof_expires_at, :utc_datetime
    end

    create index(:identity_merge_attempts, [:passwordless_challenge_id])
  end
end
