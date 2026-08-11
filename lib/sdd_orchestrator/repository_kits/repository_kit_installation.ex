defmodule SddOrchestrator.RepositoryKits.RepositoryKitInstallation do
  @moduledoc """
  One project-scoped record of one successful isolated-branch SDD kit
  application.

  An installation is created only after `RepositoryKits.apply_plan/4`
  successfully applies an owner-confirmed `RepositoryKitChangePlan` through
  `WorkerKitApply` — it records the exact package, plan, branch, resulting
  commit, per-file installed digests, and non-identifying apply evidence.

  Persistence here is hosted (PostgreSQL) only, for the same reason
  `RepositoryKitChangePlan` is: this entity is project-scoped, and the
  `Device`/`Hosted` dual-authority split is explicitly a later task's job
  ("Hosted and device storage parity", Task 6).

  Unlike `RepositoryKitPackage` and `RepositoryKitChangePlan`, this schema is
  not immutable: it carries a `state` that a later task ("Implement
  idempotent update and removal", Task 5) will transition through update and
  removal. Only a create-only changeset is exposed here — there is no update
  changeset yet, and the database allows `UPDATE` (no immutability trigger),
  because Task 5 needs it.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @states ~w(applied)
  @commit_format ~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/
  @digest_format ~r/\A[0-9a-f]{64}\z/

  @fields [
    :id,
    :project_id,
    :package_id,
    :plan_id,
    :package_digest,
    :profile_version,
    :base_commit,
    :root,
    :repository_provider,
    :repository_id,
    :branch,
    :result_commit,
    :installed_files,
    :state,
    :evidence,
    :confirmed_by_actor_ref,
    :confirmed_at
  ]

  @required_fields [
    :id,
    :project_id,
    :package_id,
    :plan_id,
    :package_digest,
    :profile_version,
    :base_commit,
    :root,
    :repository_provider,
    :repository_id,
    :branch,
    :result_commit,
    :confirmed_by_actor_ref,
    :confirmed_at
  ]

  @type t :: %__MODULE__{}

  schema "repository_kit_installations" do
    field :project_id, :binary_id
    field :package_id, :binary_id
    field :plan_id, :binary_id
    field :package_digest, :string
    field :profile_version, :integer
    field :base_commit, :string
    field :root, :string
    field :repository_provider, :string
    field :repository_id, :string
    field :branch, :string
    field :result_commit, :string
    field :installed_files, {:array, :map}, default: []
    field :state, :string, default: "applied"
    field :evidence, :map, default: %{}
    field :confirmed_by_actor_ref, :binary_id
    field :confirmed_at, :utc_datetime_usec

    timestamps()
  end

  @doc """
  Create-only changeset for one successful isolated-branch kit application.

  `state` always defaults to `"applied"` here — the only state this task
  produces; Task 5 owns the update changeset that transitions it further.
  """
  @spec create_changeset(map()) :: Ecto.Changeset.t()
  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, @fields)
    |> validate_required(@required_fields)
    |> validate_length(:root, max: 4096, count: :bytes)
    |> validate_length(:repository_provider, max: 255, count: :bytes)
    |> validate_length(:repository_id, max: 255, count: :bytes)
    |> validate_length(:branch, max: 255, count: :bytes)
    |> validate_number(:profile_version, greater_than: 0)
    |> validate_format(:base_commit, @commit_format)
    |> validate_format(:result_commit, @commit_format)
    |> validate_format(:package_digest, @digest_format)
    |> validate_inclusion(:state, @states)
    |> check_constraint(:profile_version,
      name: :repository_kit_installations_profile_version_positive
    )
    |> check_constraint(:base_commit, name: :repository_kit_installations_base_commit_shape)
    |> check_constraint(:result_commit, name: :repository_kit_installations_result_commit_shape)
    |> check_constraint(:package_digest, name: :repository_kit_installations_digest_shape)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:package_id)
    |> foreign_key_constraint(:plan_id)
    |> unique_constraint(:plan_id, name: :repository_kit_installations_plan_id_index)
  end
end
