defmodule SddOrchestrator.Privacy.ParticipationSecurityEvent do
  @moduledoc """
  One fixed, minimized participation operational-security event row
  (specs/27 Task 3, AC-03).

  Backs `SddOrchestrator.Privacy.ParticipationSecurityLog`'s retention-capable
  local sink. A row carries only an allowlisted event type, a coarse outcome,
  a fixed reason classification when the outcome requires one, the UTC
  occurrence time, and a fresh non-secret correlation identifier. The
  changeset casts exactly these five fields and nothing else — a caller
  cannot smuggle an invitation credential, email or digest, project or
  specification content, comment, evidence, repository detail, provider
  payload, secret, or unrelated identity into a row, because this schema
  declares no field that could hold one.

  Mirrors `SddOrchestrator.Privacy.ParticipationSupportElevation`'s closed
  `Ecto.Enum` vocabulary shape, but the row is append-only
  (`updated_at: false`, no revocation or mutation path) because a security
  event is a fact about one occurrence, not a lifecycle grant.

  Production sink configuration and live enforced expiry remain release-gate
  evidence (specs/27 tasks.md, "Release gates"); this schema and
  `SddOrchestrator.Privacy.Retention`'s 30-day rule provide deterministic
  local proof only.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @event_types ~w(
    invitation_credential_rejected
    invitation_acceptance_rejected
    revocation_denied
  )a

  @outcomes ~w(rejected denied failed)a

  @reasons ~w(invalid_or_expired unauthorized not_a_participant owner_cannot_leave)a

  @reasons_by_outcome %{
    rejected: ~w(invalid_or_expired)a,
    denied: ~w(unauthorized not_a_participant owner_cannot_leave)a,
    failed: []
  }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime, updated_at: false]

  @derive {Inspect, only: [:id, :event_type, :outcome, :reason, :occurred_at, :correlation_id]}

  @type t :: %__MODULE__{}

  schema "participation_security_events" do
    field :event_type, Ecto.Enum, values: @event_types
    field :outcome, Ecto.Enum, values: @outcomes
    field :reason, Ecto.Enum, values: @reasons
    field :occurred_at, :utc_datetime
    field :correlation_id, Ecto.UUID

    timestamps()
  end

  @doc "The closed, mechanically checkable participation security event-type vocabulary."
  @spec event_types() :: [atom()]
  def event_types, do: @event_types

  @doc "The closed, coarse outcome vocabulary."
  @spec outcomes() :: [atom()]
  def outcomes, do: @outcomes

  @doc "The reason atoms approved for `outcome`; empty when that outcome requires none."
  @spec reasons(atom()) :: [atom()]
  def reasons(outcome), do: Map.get(@reasons_by_outcome, outcome, [])

  @doc """
  Builds the changeset for one event row. `attrs` is cast against exactly
  `[:event_type, :outcome, :reason, :occurred_at, :correlation_id]` — any
  other key `attrs` carries is silently dropped by `cast/3` and never reaches
  the row.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(event, attrs) do
    event
    |> cast(attrs, [:event_type, :outcome, :reason, :occurred_at, :correlation_id])
    |> validate_required([:event_type, :outcome, :occurred_at, :correlation_id])
    |> validate_inclusion(:event_type, @event_types)
    |> validate_inclusion(:outcome, @outcomes)
    |> validate_reason_for_outcome()
    |> check_constraint(:event_type, name: :participation_security_events_event_type_allowed)
    |> check_constraint(:outcome, name: :participation_security_events_outcome_allowed)
    |> check_constraint(:reason, name: :participation_security_events_reason_allowed)
  end

  defp validate_reason_for_outcome(changeset) do
    outcome = get_field(changeset, :outcome)
    reason = get_field(changeset, :reason)
    approved = reasons(outcome)

    cond do
      is_nil(outcome) ->
        changeset

      is_nil(reason) and approved == [] ->
        changeset

      is_nil(reason) ->
        add_error(changeset, :reason, "is required for this outcome")

      reason in approved ->
        changeset

      true ->
        add_error(changeset, :reason, "is not approved for this outcome")
    end
  end
end
