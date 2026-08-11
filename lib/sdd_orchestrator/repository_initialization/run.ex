defmodule SddOrchestrator.RepositoryInitialization.Run do
  @moduledoc """
  One authorized, plan-bound working-agent staging lifecycle (specs/16 Task 4,
  `entity:RepositoryInitializationRun`).

  A run is created only after `RepositoryInitialization.confirm_plan/2` has
  bound one confirmed plan, and freezes that plan's kit choice/package
  identity at creation time — defense in depth against a later plan mutation,
  even though `Plan`'s own changed-input invalidation rules should already
  prevent that from mattering in practice. `idempotency_key` is unique so a
  caller retrying the same run request never starts two staging builds.

  `state` walks `pending -> running -> (completed | failed | canceled)`.
  `progress` accumulates ordered typed events — `%{"type" => "progress" |
  "evidence" | "failed", "occurred_at" => iso8601, "payload" => map}` —
  matching `Delivery.AgentAdapter.observe/2`'s own normalized vocabulary
  (minus `blocked`, which does not apply to `StagingBuilder`'s fully
  deterministic build).

  Never carries an absolute filesystem path: `StagingWorkspace` always
  recomputes a run's staging directory from the configured root and this
  struct's own `id`, exactly as `Delivery.Worker.Workspace` never stores one
  either.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  @states ~w(pending running completed failed canceled)
  @kit_choices ~w(included declined)

  @type t :: %__MODULE__{}

  schema "repository_initialization_runs" do
    field :plan_id, :binary_id
    field :device_workspace_id, :binary_id
    field :worker_id, :binary_id
    field :dispatch_id, :string

    field :idempotency_key, :string

    field :state, :string, default: "pending"

    field :kit_choice, :string
    field :kit_package_id, :binary_id
    field :kit_package_digest, :string

    field :progress, {:array, :map}, default: []

    field :failure_reason, :string
    field :cancel_requested_at, :utc_datetime
    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime

    timestamps()
  end

  @doc "Changeset for a newly created run, always at state `\"pending\"`."
  def create_changeset(run, attrs) do
    run
    |> cast(attrs, [
      :plan_id,
      :device_workspace_id,
      :worker_id,
      :dispatch_id,
      :idempotency_key,
      :state,
      :kit_choice,
      :kit_package_id,
      :kit_package_digest
    ])
    |> validate_required([
      :plan_id,
      :device_workspace_id,
      :worker_id,
      :dispatch_id,
      :idempotency_key,
      :state,
      :kit_choice
    ])
    |> validate_inclusion(:state, @states)
    |> validate_inclusion(:kit_choice, @kit_choices)
    |> unique_constraint(:idempotency_key,
      name: :repository_initialization_runs_idempotency_key_index
    )
    |> foreign_key_constraint(:plan_id)
  end

  @doc "Changeset that appends to the ordered `progress` activity log."
  def progress_changeset(run, attrs) do
    run
    |> cast(attrs, [:progress])
    |> validate_required([:progress])
  end

  @doc "Changeset for a state transition (`running`, `completed`, `failed`, `canceled`)."
  def state_changeset(run, attrs) do
    run
    |> cast(attrs, [:state, :failure_reason, :started_at, :finished_at, :progress])
    |> validate_required([:state])
    |> validate_inclusion(:state, @states)
  end

  @doc "Changeset that records a cancellation request, checked at the next build checkpoint."
  def cancel_request_changeset(run, attrs) do
    run
    |> cast(attrs, [:cancel_requested_at])
    |> validate_required([:cancel_requested_at])
  end

  @doc "The persisted run states."
  def states, do: @states

  @doc "The persisted kit-choice snapshot values."
  def kit_choices, do: @kit_choices
end
