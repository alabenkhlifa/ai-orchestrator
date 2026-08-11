defmodule SddOrchestrator.RepositoryInitialization.Result do
  @moduledoc """
  One immutable successful empty-repository initialization outcome (specs/16
  Task 5, `entity:RepositoryInitializationResult`).

  Created exactly once per `RepositoryInitialization.Run` (`run_id` is
  unique) — this is what makes idempotent replay real: a repeated publish
  attempt for the same run finds this row first and never re-commits or
  re-publishes (AC-11). Never carries the real target path, only the plan's
  own opaque `target_reference`, matching AC-01's rule.

  `onboarding_handoff_state` starts `"pending"` and stays that way until
  whichever later task consumes this result for normal local-onboarding
  handoff (Task 6) advances it to `"completed"` — not this task's concern.

  `project_id`/`specification_id` (Task 6) record the device project and
  authoritative specification the handoff created, once. Neither is a
  foreign key: device projects and device specifications live only in the
  worker-owned device-local store, never in hosted PostgreSQL.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  @kit_choices ~w(included declined)
  @handoff_states ~w(pending completed)

  @type t :: %__MODULE__{}

  schema "repository_initialization_results" do
    field :plan_id, :binary_id
    field :run_id, :binary_id
    field :target_reference, :string

    field :commit_sha, :string
    field :tree_digest, :string

    field :kit_choice, :string
    field :kit_package_id, :binary_id
    field :kit_package_digest, :string

    field :check_evidence, {:array, :map}, default: []

    field :completed_at, :utc_datetime
    field :onboarding_handoff_state, :string, default: "pending"

    field :project_id, :binary_id
    field :specification_id, :binary_id

    timestamps()
  end

  @doc "Changeset for one newly recorded successful publication."
  def create_changeset(result, attrs) do
    result
    |> cast(attrs, [
      :plan_id,
      :run_id,
      :target_reference,
      :commit_sha,
      :tree_digest,
      :kit_choice,
      :kit_package_id,
      :kit_package_digest,
      :check_evidence,
      :completed_at,
      :onboarding_handoff_state
    ])
    |> validate_required([
      :plan_id,
      :run_id,
      :target_reference,
      :commit_sha,
      :tree_digest,
      :kit_choice,
      :check_evidence,
      :completed_at,
      :onboarding_handoff_state
    ])
    |> validate_inclusion(:kit_choice, @kit_choices)
    |> validate_inclusion(:onboarding_handoff_state, @handoff_states)
    |> unique_constraint(:run_id, name: :repository_initialization_results_run_id_index)
    |> foreign_key_constraint(:plan_id)
    |> foreign_key_constraint(:run_id)
  end

  @doc "Changeset that records the completed onboarding/specification handoff."
  def handoff_changeset(result, attrs) do
    result
    |> cast(attrs, [:project_id, :specification_id, :onboarding_handoff_state])
    |> validate_required([:onboarding_handoff_state])
    |> validate_inclusion(:onboarding_handoff_state, @handoff_states)
  end
end
