defmodule SddOrchestrator.Delivery.RunAttempt do
  @moduledoc """
  One exclusive worker execution inside a run.

  Every continuation — an automatic or manual retry, a resume after an accepted
  blocking answer, or a review rejection — is a new numbered attempt of the
  same run, on the same branch and workspace. That is what lets the product
  keep accepted work while still refusing to let two executions of one run be
  current at the same time.

  Exclusivity is enforced in three layers that fail closed independently. The
  attempt number is unique per run, so an ordering gap is visible rather than
  overwritten. A partial unique index permits at most one attempt of a run in a
  non-terminal state. And each attempt carries a fence token that only ever
  increases, so a superseded worker's late events are rejected even if it still
  believes it holds the lease.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias SddOrchestrator.Delivery.{AgentRun, ExecutionManifest}

  @states ~w(pending dispatched running succeeded failed canceled superseded)
  @current_states ~w(pending dispatched running)
  @terminal_states ~w(succeeded failed canceled superseded)

  @transitions %{
    "pending" => ~w(dispatched canceled failed superseded),
    "dispatched" => ~w(running failed canceled superseded),
    "running" => ~w(succeeded failed canceled superseded),
    "succeeded" => [],
    "failed" => [],
    "canceled" => [],
    "superseded" => []
  }

  @max_owner_bytes 200

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  @type t :: %__MODULE__{}

  schema "run_attempts" do
    field :attempt_number, :integer
    field :state, :string, default: "pending"
    field :continuation_reason, :string
    field :effective_revision_id, :string
    field :effective_revision_digest, :string
    field :manifest_digest, :string
    field :lease_owner, :string
    field :lease_expires_at, :utc_datetime
    field :fence_token, :integer
    field :last_sequence, :integer, default: 0
    field :state_version, :integer, default: 1

    belongs_to :run, AgentRun

    timestamps()
  end

  @spec states() :: [String.t()]
  def states, do: @states

  @spec current_states() :: [String.t()]
  def current_states, do: @current_states

  @spec terminal_states() :: [String.t()]
  def terminal_states, do: @terminal_states

  @spec transitions() :: %{String.t() => [String.t()]}
  def transitions, do: @transitions

  @spec legal_transition?(String.t(), String.t()) :: boolean()
  def legal_transition?(from, to), do: to in Map.get(@transitions, from, [])

  @spec current?(t()) :: boolean()
  def current?(%__MODULE__{state: state}), do: state in @current_states

  @doc "Reports whether a lease is still held at `now`."
  @spec lease_active?(t(), DateTime.t()) :: boolean()
  def lease_active?(%__MODULE__{lease_expires_at: nil}, _now), do: false

  def lease_active?(%__MODULE__{lease_expires_at: expires_at}, now),
    do: DateTime.compare(expires_at, now) == :gt

  @doc """
  Creates one ordered attempt bound to its immutable execution manifest.

  The fence token is supplied by the caller because it must be monotonic across
  the whole run, which only the run-level transaction can know.
  """
  def create_changeset(attempt, attrs) do
    attempt
    |> cast(attrs, [
      :run_id,
      :attempt_number,
      :continuation_reason,
      :effective_revision_id,
      :effective_revision_digest,
      :manifest_digest,
      :fence_token
    ])
    |> put_change(:state, "pending")
    |> put_change(:last_sequence, 0)
    |> put_change(:state_version, 1)
    |> validate_required([
      :run_id,
      :attempt_number,
      :continuation_reason,
      :effective_revision_id,
      :effective_revision_digest,
      :manifest_digest,
      :fence_token
    ])
    |> validate_inclusion(:continuation_reason, ExecutionManifest.continuation_reasons())
    |> validate_number(:attempt_number, greater_than: 0)
    |> validate_number(:fence_token, greater_than: 0)
    |> apply_constraints()
  end

  @doc "Applies one legal attempt transition against an expected state version."
  def transition_changeset(%__MODULE__{} = attempt, to, expected_state_version) do
    attempt
    |> change(%{})
    |> validate_expected_version(expected_state_version)
    |> validate_transition(to)
    |> put_change(:state, to)
    |> release_lease_when_terminal(to)
    |> optimistic_lock(:state_version)
    |> apply_constraints()
  end

  @doc """
  Claims the execution lease for one worker until `expires_at`.

  Claiming is only legal for a current attempt: a terminal attempt cannot be
  revived by a worker that reconnects late.
  """
  def claim_lease_changeset(%__MODULE__{} = attempt, owner, expires_at, expected_state_version) do
    attempt
    |> change(%{})
    |> validate_expected_version(expected_state_version)
    |> validate_current()
    |> put_change(:lease_owner, owner)
    |> put_change(:lease_expires_at, expires_at)
    |> validate_required([:lease_owner, :lease_expires_at])
    |> validate_length(:lease_owner, max: @max_owner_bytes, count: :bytes)
    |> optimistic_lock(:state_version)
    |> apply_constraints()
  end

  @doc """
  Records the highest observed event sequence for this attempt.

  The sequence only ever moves forward, so a duplicated or out-of-order worker
  event is rejected here rather than being applied twice downstream.
  """
  def observe_sequence_changeset(%__MODULE__{} = attempt, sequence, expected_state_version) do
    attempt
    |> change(%{})
    |> validate_expected_version(expected_state_version)
    |> put_change(:last_sequence, sequence)
    |> validate_sequence_advance(sequence)
    |> optimistic_lock(:state_version)
    |> apply_constraints()
  end

  @doc "The device-adapter value shape, with no Ecto or hosted dependency."
  @spec to_value(t()) :: map()
  def to_value(%__MODULE__{} = attempt) do
    %{
      "id" => attempt.id,
      "run_id" => attempt.run_id,
      "attempt_number" => attempt.attempt_number,
      "state" => attempt.state,
      "continuation_reason" => attempt.continuation_reason,
      "effective_revision_id" => attempt.effective_revision_id,
      "effective_revision_digest" => attempt.effective_revision_digest,
      "manifest_digest" => attempt.manifest_digest,
      "lease_owner" => attempt.lease_owner,
      "lease_expires_at" =>
        attempt.lease_expires_at && DateTime.to_iso8601(attempt.lease_expires_at),
      "fence_token" => attempt.fence_token,
      "last_sequence" => attempt.last_sequence,
      "state_version" => attempt.state_version
    }
  end

  @spec from_value(map()) :: {:ok, t()} | {:error, :invalid_attempt_value}
  def from_value(%{} = value) do
    with true <- value["state"] in @states,
         true <- is_integer(value["attempt_number"]) and value["attempt_number"] > 0,
         true <- is_integer(value["fence_token"]) and value["fence_token"] > 0,
         true <- is_integer(value["last_sequence"]) and value["last_sequence"] >= 0,
         true <- is_integer(value["state_version"]) and value["state_version"] > 0,
         true <- is_binary(value["id"]) and is_binary(value["run_id"]),
         {:ok, expires_at} <- decode_expiry(value["lease_expires_at"]) do
      {:ok,
       %__MODULE__{
         id: value["id"],
         run_id: value["run_id"],
         attempt_number: value["attempt_number"],
         state: value["state"],
         continuation_reason: value["continuation_reason"],
         effective_revision_id: value["effective_revision_id"],
         effective_revision_digest: value["effective_revision_digest"],
         manifest_digest: value["manifest_digest"],
         lease_owner: value["lease_owner"],
         lease_expires_at: expires_at,
         fence_token: value["fence_token"],
         last_sequence: value["last_sequence"],
         state_version: value["state_version"]
       }}
    else
      _invalid -> {:error, :invalid_attempt_value}
    end
  end

  def from_value(_value), do: {:error, :invalid_attempt_value}

  defp decode_expiry(nil), do: {:ok, nil}

  defp decode_expiry(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, DateTime.truncate(datetime, :second)}
      {:error, _reason} -> :error
    end
  end

  defp decode_expiry(_value), do: :error

  # A terminal attempt holds no lease: keeping one would let an expired worker
  # look like the current executor during reconciliation.
  defp release_lease_when_terminal(changeset, to) when to in @terminal_states do
    changeset
    |> put_change(:lease_owner, nil)
    |> put_change(:lease_expires_at, nil)
  end

  defp release_lease_when_terminal(changeset, _to), do: changeset

  defp validate_expected_version(changeset, expected) do
    if changeset.data.state_version == expected do
      changeset
    else
      add_error(changeset, :state_version, "is stale")
    end
  end

  defp validate_transition(changeset, to) do
    from = changeset.data.state

    if legal_transition?(from, to) do
      changeset
    else
      add_error(changeset, :state, "cannot move from #{from} to #{to}")
    end
  end

  defp validate_current(changeset) do
    if changeset.data.state in @current_states do
      changeset
    else
      add_error(changeset, :state, "is not a current attempt")
    end
  end

  defp validate_sequence_advance(changeset, sequence) do
    if is_integer(sequence) and sequence > changeset.data.last_sequence do
      changeset
    else
      add_error(changeset, :last_sequence, "must move forward")
    end
  end

  defp apply_constraints(changeset) do
    changeset
    |> validate_inclusion(:state, @states)
    |> validate_number(:state_version, greater_than: 0)
    |> validate_number(:last_sequence, greater_than_or_equal_to: 0)
    |> check_constraint(:state, name: :run_attempts_state_allowed)
    |> check_constraint(:lease_owner, name: :run_attempts_lease_pairing)
    |> unique_constraint([:run_id, :attempt_number])
    |> unique_constraint([:run_id, :fence_token])
    |> unique_constraint(:state, name: :run_attempts_one_current_attempt)
    |> foreign_key_constraint(:run_id)
  end
end
