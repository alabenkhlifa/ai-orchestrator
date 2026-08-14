defmodule SddOrchestrator.Privacy.ParticipationCleanupRequest do
  @moduledoc """
  One restricted, non-identity-bearing cleanup or reconciliation request
  (specs/28 Task 2, AC-02, AC-03).

  A participation deletion or anonymization action propagates to a fixed,
  closed set of non-backup destinations — `:configured_processors`,
  `:caches`, `:indexes`, and `:exports`, matching
  `SddOrchestrator.Privacy.Rights`'s existing `anonymization_propagation/0`
  `pending_propagation` list — through one row per destination.

  This is a restricted reconciliation store, not a second copy of
  participation identity data. `subject_ref` is a caller-minted opaque
  correlation reference for one approved deletion or anonymization action; it
  is never the raw account id, hosted-identity id, participant id, email, or
  display name, so this table can never become a new identity index. Every
  other field is a minimum destination, action, idempotency, acknowledgement,
  attempt, timing, or normalized-failure field — see design.md's "Data and
  Access Boundaries". `SddOrchestrator.Privacy.ParticipationPropagation` owns
  every write to this schema; issuing, acknowledging, and retrying are all
  separate changesets so each state transition is independently provable and
  the acknowledgement/retry-pairing check constraints stay honest about which
  fields a given state may carry.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @actions ~w(delete anonymize)a
  @destinations ~w(configured_processors caches indexes exports)a
  @states ~w(pending acknowledged retry_pending)a
  @failure_reasons ~w(timeout destination_unavailable rejected transient_error)a

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "participation_cleanup_requests" do
    field :subject_ref, :binary_id
    field :action, Ecto.Enum, values: @actions
    field :destination, Ecto.Enum, values: @destinations
    field :idempotency_key, :string

    field :state, Ecto.Enum, values: @states, default: :pending
    field :failure_reason, Ecto.Enum, values: @failure_reasons
    field :attempt_count, :integer, default: 0

    field :requested_at, :utc_datetime_usec
    field :last_attempted_at, :utc_datetime_usec
    field :acknowledged_at, :utc_datetime_usec

    timestamps()
  end

  @doc "The closed action vocabulary a cleanup request may carry."
  @spec actions() :: [atom()]
  def actions, do: @actions

  @doc """
  The fixed, closed set of non-backup cleanup destinations, matching
  `SddOrchestrator.Privacy.Rights`'s `anonymization_propagation/0`
  `pending_propagation` list exactly.
  """
  @spec destinations() :: [atom()]
  def destinations, do: @destinations

  @doc "The closed acknowledgement/attempt state vocabulary."
  @spec states() :: [atom()]
  def states, do: @states

  @doc "The closed normalized-failure vocabulary a retry-pending request may carry."
  @spec failure_reasons() :: [atom()]
  def failure_reasons, do: @failure_reasons

  @doc """
  Derives the deterministic idempotency key for one subject, action, and
  destination. Stable across repeated calls, so a caller never needs to read
  the row back first to know what key an adapter will see on retry.
  """
  @spec idempotency_key(Ecto.UUID.t(), atom(), atom()) :: String.t()
  def idempotency_key(subject_ref, action, destination)
      when is_binary(subject_ref) and action in @actions and destination in @destinations do
    :sha256
    |> :crypto.hash("#{subject_ref}:#{action}:#{destination}")
    |> Base.encode16(case: :lower)
  end

  @doc """
  Issues one new cleanup request row. `state` always starts `:pending`;
  attempt, acknowledgement, and failure fields all start empty. The unique
  `(subject_ref, action, destination)` index is the idempotency boundary —
  callers use `on_conflict: :nothing` against it and re-fetch rather than
  treat a conflict as an error.
  """
  @spec issue_changeset(t(), map()) :: Ecto.Changeset.t()
  def issue_changeset(%__MODULE__{} = request, attrs) do
    request
    |> cast(attrs, [:subject_ref, :action, :destination, :idempotency_key, :requested_at])
    |> put_default_requested_at()
    |> validate_required([:subject_ref, :action, :destination, :idempotency_key, :requested_at])
    |> validate_inclusion(:action, @actions)
    |> validate_inclusion(:destination, @destinations)
    |> put_change(:state, :pending)
    |> unique_constraint([:subject_ref, :action, :destination],
      name: :participation_cleanup_requests_subject_action_destination_index
    )
    |> check_constraint(:action, name: :participation_cleanup_requests_action_allowed)
    |> check_constraint(:destination, name: :participation_cleanup_requests_destination_allowed)
    |> check_constraint(:state, name: :participation_cleanup_requests_state_allowed)
    |> check_constraint(:failure_reason,
      name: :participation_cleanup_requests_failure_reason_allowed
    )
    |> check_constraint(:acknowledged_at,
      name: :participation_cleanup_requests_acknowledgement_pairing
    )
    |> check_constraint(:failure_reason, name: :participation_cleanup_requests_retry_pairing)
  end

  @doc """
  Acknowledges one request: the configured destination confirmed cleanup.
  Clears any prior failure classification, since a failure record has no
  purpose once the same request later succeeds.
  """
  @spec acknowledge_changeset(t(), map()) :: Ecto.Changeset.t()
  def acknowledge_changeset(%__MODULE__{} = request, attrs) do
    request
    |> cast(attrs, [:acknowledged_at, :last_attempted_at])
    |> put_default(:acknowledged_at)
    |> put_default(:last_attempted_at)
    |> put_change(:state, :acknowledged)
    |> put_change(:failure_reason, nil)
    |> put_change(:attempt_count, request.attempt_count + 1)
    |> validate_required([:acknowledged_at, :last_attempted_at])
    |> check_constraint(:state, name: :participation_cleanup_requests_state_allowed)
    |> check_constraint(:acknowledged_at,
      name: :participation_cleanup_requests_acknowledgement_pairing
    )
    |> check_constraint(:failure_reason, name: :participation_cleanup_requests_retry_pairing)
  end

  @doc """
  Transitions one request to restricted retry-pending state after a
  normalized destination failure. Never sets or clears `acknowledged_at`: a
  request that has already been acknowledged is not retried.
  """
  @spec retry_changeset(t(), map()) :: Ecto.Changeset.t()
  def retry_changeset(%__MODULE__{} = request, attrs) do
    request
    |> cast(attrs, [:failure_reason, :last_attempted_at])
    |> put_default(:last_attempted_at)
    |> put_change(:state, :retry_pending)
    |> put_change(:attempt_count, request.attempt_count + 1)
    |> validate_required([:failure_reason, :last_attempted_at])
    |> validate_inclusion(:failure_reason, @failure_reasons)
    |> check_constraint(:state, name: :participation_cleanup_requests_state_allowed)
    |> check_constraint(:failure_reason,
      name: :participation_cleanup_requests_failure_reason_allowed
    )
    |> check_constraint(:failure_reason, name: :participation_cleanup_requests_retry_pairing)
    |> check_constraint(:acknowledged_at,
      name: :participation_cleanup_requests_acknowledgement_pairing
    )
  end

  @doc "Reports whether the request still needs reconciliation attention."
  @spec incomplete?(t()) :: boolean()
  def incomplete?(%__MODULE__{state: state}), do: state in [:pending, :retry_pending]

  defp put_default_requested_at(changeset) do
    case get_field(changeset, :requested_at) do
      nil -> put_change(changeset, :requested_at, DateTime.utc_now())
      _present -> changeset
    end
  end

  defp put_default(changeset, field) do
    case get_field(changeset, field) do
      nil -> put_change(changeset, field, DateTime.utc_now())
      _present -> changeset
    end
  end
end
