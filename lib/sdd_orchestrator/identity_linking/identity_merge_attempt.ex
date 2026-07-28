defmodule SddOrchestrator.IdentityLinking.IdentityMergeAttempt do
  @moduledoc """
  Transient state for one GitHub-to-passwordless identity merge.

  Binds the absorbed (GitHub) account, the surviving (passwordless) account, and
  the matched candidate hosted identity by id, plus the two-proof and
  confirmation markers, so the merge can lock and commit atomically. It carries no
  candidate email, project, repository, session, or secret, and expires in minutes
  so an unproven candidate never lingers.

  Personal identifiers of the candidate are never placed here, so the record
  cannot disclose the matched account before the passwordless proof succeeds.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @statuses ~w(detected awaiting_confirmation conflict committed aborted)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  @derive {Inspect,
           only: [
             :id,
             :status,
             :absorbed_account_id,
             :surviving_account_id,
             :expires_at,
             :committed_at
           ]}

  @type t :: %__MODULE__{}

  schema "identity_merge_attempts" do
    field :status, :string, default: "detected"
    field :github_proven_at, :utc_datetime
    field :passwordless_proven_at, :utc_datetime
    field :passwordless_challenge_id, :binary_id
    field :passwordless_proof_digest, :binary, redact: true
    field :passwordless_proof_salt, :binary, redact: true
    field :passwordless_proof_expires_at, :utc_datetime
    field :confirmed_at, :utc_datetime
    field :committed_at, :utc_datetime
    field :expires_at, :utc_datetime

    belongs_to :absorbed_account, SddOrchestrator.Accounts.Account
    belongs_to :surviving_account, SddOrchestrator.Accounts.Account
    belongs_to :candidate_hosted_identity, SddOrchestrator.Accounts.HostedIdentity

    timestamps()
  end

  @doc "Changeset that opens a transient candidate on a fresh GitHub authentication."
  def detect_changeset(attempt, attrs) do
    attempt
    |> cast(attrs, [
      :absorbed_account_id,
      :surviving_account_id,
      :candidate_hosted_identity_id,
      :github_proven_at,
      :expires_at
    ])
    |> put_change(:status, "detected")
    |> validate_required([
      :absorbed_account_id,
      :surviving_account_id,
      :candidate_hosted_identity_id,
      :github_proven_at,
      :expires_at
    ])
    |> validate_no_self_merge()
    |> foreign_key_constraint(:absorbed_account_id)
    |> foreign_key_constraint(:surviving_account_id)
    |> foreign_key_constraint(:candidate_hosted_identity_id)
    |> unique_constraint(:absorbed_account_id,
      name: :identity_merge_attempts_one_live_absorbed_index
    )
  end

  @doc "Refreshes an existing live attempt's candidate binding and expiry."
  def refresh_changeset(attempt, attrs) do
    attempt
    |> cast(attrs, [
      :surviving_account_id,
      :candidate_hosted_identity_id,
      :github_proven_at,
      :expires_at
    ])
    |> put_change(:status, "detected")
    |> validate_required([
      :surviving_account_id,
      :candidate_hosted_identity_id,
      :github_proven_at,
      :expires_at
    ])
    |> validate_no_self_merge()
  end

  @doc """
  Stores a fresh passwordless-proof challenge (salted digest, salt, expiry) and
  its public reference id, and refreshes the attempt expiry so the flow stays
  live while the user proves the candidate email.
  """
  def request_proof_changeset(attempt, attrs) do
    attempt
    |> cast(attrs, [
      :passwordless_challenge_id,
      :passwordless_proof_digest,
      :passwordless_proof_salt,
      :passwordless_proof_expires_at,
      :expires_at
    ])
    |> validate_required([
      :passwordless_challenge_id,
      :passwordless_proof_digest,
      :passwordless_proof_salt,
      :passwordless_proof_expires_at,
      :expires_at
    ])
  end

  @doc """
  Records a successful passwordless proof and clears the single-use challenge so
  it cannot be replayed. Moves the attempt to `awaiting_confirmation`.
  """
  def record_proof_changeset(attempt) do
    change(attempt,
      passwordless_proven_at: truncated_now(),
      passwordless_proof_digest: nil,
      passwordless_proof_salt: nil,
      status: "awaiting_confirmation"
    )
  end

  @doc "Records the explicit user confirmation. The last gate before commit."
  def confirm_changeset(attempt) do
    change(attempt, confirmed_at: truncated_now())
  end

  @doc "Marks an attempt conflicted (a preflight collision blocks the merge)."
  def conflict_changeset(attempt) do
    change(attempt, status: "conflict")
  end

  @doc "Marks an attempt aborted (idempotent, non-mutating for identities)."
  def abort_changeset(attempt) do
    change(attempt, status: "aborted")
  end

  @doc "Changeset for a status transition to one of the known lifecycle states."
  def status_changeset(attempt, attrs) do
    attempt
    |> cast(attrs, [
      :status,
      :passwordless_proven_at,
      :passwordless_challenge_id,
      :confirmed_at,
      :committed_at
    ])
    |> validate_inclusion(:status, @statuses)
  end

  @doc "The known lifecycle states."
  def statuses, do: @statuses

  defp truncated_now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  # A merge always joins two distinct accounts; the same account on both sides is
  # a programming error, not a valid merge.
  defp validate_no_self_merge(changeset) do
    absorbed = get_field(changeset, :absorbed_account_id)
    surviving = get_field(changeset, :surviving_account_id)

    if not is_nil(absorbed) and absorbed == surviving do
      add_error(changeset, :surviving_account_id, "cannot merge an account with itself")
    else
      changeset
    end
  end
end
