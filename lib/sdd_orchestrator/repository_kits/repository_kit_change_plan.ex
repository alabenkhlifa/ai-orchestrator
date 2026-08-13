defmodule SddOrchestrator.RepositoryKits.RepositoryKitChangePlan do
  @moduledoc """
  One immutable, project-scoped, worker-local repository-kit change plan.

  A plan is the exact, read-only comparison between one immutable
  `RepositoryKitPackage` and the repository tree at one exact base commit. It
  is bound to the approved execution profile version that supplied that
  commit and to the existing-instruction precedence used to classify every
  operation, so a plan can never be replayed against a different profile,
  commit, or package without a fresh comparison.

  Plans are append-only: there is no update changeset here, and the database
  additionally rejects any `UPDATE` through an immutability trigger, mirroring
  `RepositoryKitPackage` and `RepositoryExecutionProfile`. "The current plan"
  for a project is derived at read time as the most recent non-expired row —
  there is no separate mutable pointer to a "latest" plan.

  `expires_at` is fifteen minutes after creation. That window is a pure
  engineering parameter, not a product decision: short enough that a
  repository or profile that changed underneath the plan is unlikely to
  silently outlive it before an owner reviews and confirms (a later task),
  long enough to read one rendered diff without the plan expiring mid-review.
  A plan past its window is never a valid confirmation target; building a
  fresh plan is always required instead of extending an old one.

  Persistence follows the same `Device`/`Hosted` dual-authority split
  `RepositoryAssessments.ProfileStore` uses, through
  `RepositoryKits.ChangePlanStore` (Task 7). `RepositoryKitPackage` (Task 1)
  is a global catalog and never needed a device-authoritative store, but this
  entity is project-scoped: a device-authoritative project builds, reads, and
  removal-plans its own change plan entirely on-device, and a hosted project's
  plan lives in PostgreSQL exactly as before. `to_value/1` and `from_value/1`
  serialize this schema's exact immutable value for the device adapter,
  mirroring `RepositoryExecutionProfile`'s own pair.

  `plan_type` distinguishes an initial `"install"` plan (Task 2, compared
  against the live repository tree) from an `"update"` plan (Task 5,
  compared against the currently-installed kit's own recorded file ownership
  as well as the live repository tree — see
  `SddOrchestrator.RepositoryKits.WorkerKitUpdateComparison`) and a
  `"removal"` plan (Task 6, compared only against the currently-installed
  kit's own recorded file ownership — see
  `SddOrchestrator.RepositoryKits.WorkerKitRemovalComparison`). An update
  introduces the `"drifted"` conflict severity: a kit-owned file whose live
  content no longer matches what was recorded at install or last update. A
  removal plan reuses the same `"drifted"` severity for the exact same
  reason, and introduces the `"delete"` operation kind: a kit-owned file
  still proven unchanged since it was recorded, safe to remove.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  @kinds ~w(create delete omit conflict)
  @severities ~w(ordinary safety drifted)
  @plan_types ~w(install update removal)
  @commit_format ~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/
  @digest_format ~r/\A[0-9a-f]{64}\z/

  @operation_keys MapSet.new(~w(
    path kind conflict_severity proposed_sha256 existing_sha256 proposed_size
    proposed_executable proposed_content_base64 reason
  ))

  @fields [
    :id,
    :project_id,
    :package_id,
    :package_digest,
    :profile_version,
    :base_commit,
    :root,
    :repository_provider,
    :repository_id,
    :target_branch,
    :operations,
    :safety_blocked,
    :has_ordinary_conflicts,
    :expires_at,
    :plan_type,
    :inserted_at
  ]

  # `:inserted_at` is deliberately absent here. The hosted path never
  # supplies it in attrs and relies on Ecto's own `timestamps()` to
  # autogenerate it at `Repo.insert` time (unaffected by `:inserted_at`
  # simply being castable above — casting only acts on keys attrs actually
  # has); the device path supplies it explicitly before `build/1`, mirroring
  # `RepositoryExecutionProfile.approved/4`. Neither path treats it as a
  # normal required scalar the caller must always pass.
  @required_fields [
    :id,
    :project_id,
    :package_id,
    :package_digest,
    :profile_version,
    :base_commit,
    :root,
    :repository_provider,
    :repository_id,
    :target_branch,
    :operations,
    :expires_at
  ]

  @value_keys MapSet.new(Enum.map(@fields, &Atom.to_string/1))

  @type t :: %__MODULE__{}

  schema "repository_kit_change_plans" do
    field :project_id, :binary_id
    field :package_id, :binary_id
    field :package_digest, :string
    field :profile_version, :integer
    field :base_commit, :string
    field :root, :string
    field :repository_provider, :string
    field :repository_id, :string
    field :target_branch, :string
    field :operations, {:array, :map}
    field :safety_blocked, :boolean, default: false
    field :has_ordinary_conflicts, :boolean, default: false
    field :expires_at, :utc_datetime_usec
    field :plan_type, :string, default: "install"

    timestamps()
  end

  @doc """
  Create-only hosted changeset layering database-only constraints onto the
  shared pure-validation changeset.

  `safety_blocked` and `has_ordinary_conflicts` are always derived by the
  shared changeset from `operations`, never trusted from caller-supplied
  attrs, so the two summary flags can never disagree with the operations
  they summarize.
  """
  @spec create_changeset(map()) :: Ecto.Changeset.t()
  def create_changeset(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> check_constraint(:profile_version,
      name: :repository_kit_change_plans_profile_version_positive
    )
    |> check_constraint(:base_commit, name: :repository_kit_change_plans_commit_shape)
    |> check_constraint(:package_digest, name: :repository_kit_change_plans_digest_shape)
    |> check_constraint(:plan_type, name: :repository_kit_change_plans_plan_type_shape)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:package_id)
  end

  @doc """
  Builds one in-memory, pure-validated plan without any database constraint.

  Shares the exact same field validation `create_changeset/1` uses; only the
  database-only constraints are skipped, since there is no database here.
  Used both by `from_value/1` (restoring a device-authoritative stored value)
  and by the device change-plan-store adapter (validating a plan before it is
  ever written to device storage).
  """
  @spec build(map()) :: {:ok, t()} | {:error, :invalid_plan}
  def build(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> apply_action(:insert)
    |> case do
      {:ok, plan} -> {:ok, plan}
      {:error, _changeset} -> {:error, :invalid_plan}
    end
  end

  @doc "Serializes the exact device-authoritative value without Ecto metadata."
  @spec to_value(t()) :: map()
  def to_value(%__MODULE__{} = plan) do
    plan
    |> Map.take(@fields)
    |> Map.new(fn
      {key, %DateTime{} = value} -> {Atom.to_string(key), DateTime.to_iso8601(value)}
      {key, value} -> {Atom.to_string(key), value}
    end)
  end

  @doc "Restores only the exact immutable device value."
  @spec from_value(term()) :: {:ok, t()} | {:error, :invalid_plan}
  def from_value(value) when is_map(value) do
    with true <- MapSet.new(Map.keys(value)) == @value_keys,
         {:ok, expires_at, 0} <- DateTime.from_iso8601(value["expires_at"]),
         {:ok, inserted_at, 0} <- DateTime.from_iso8601(value["inserted_at"]) do
      value
      |> Map.new(fn {key, field_value} -> {String.to_existing_atom(key), field_value} end)
      |> Map.merge(%{expires_at: expires_at, inserted_at: inserted_at})
      |> build()
    else
      _invalid -> {:error, :invalid_plan}
    end
  rescue
    _error -> {:error, :invalid_plan}
  end

  def from_value(_value), do: {:error, :invalid_plan}

  defp changeset(plan, attrs) do
    plan
    |> cast(attrs, @fields)
    |> validate_required(@required_fields)
    |> validate_length(:root, max: 4096, count: :bytes)
    |> validate_length(:repository_provider, max: 255, count: :bytes)
    |> validate_length(:repository_id, max: 255, count: :bytes)
    |> validate_length(:target_branch, max: 255, count: :bytes)
    |> validate_number(:profile_version, greater_than: 0)
    |> validate_format(:base_commit, @commit_format)
    |> validate_format(:package_digest, @digest_format)
    |> validate_change(:operations, &validate_operations/2)
    |> validate_inclusion(:plan_type, @plan_types)
    |> derive_summary_flags()
  end

  defp validate_operations(:operations, operations) when is_list(operations) do
    if operations != [] and Enum.all?(operations, &valid_operation?/1) do
      []
    else
      [
        operations:
          "must be a non-empty list of valid create, delete, omit, or conflict operations"
      ]
    end
  end

  defp validate_operations(:operations, _operations), do: [operations: "must be a list"]

  defp valid_operation?(%{} = operation) do
    keys = operation |> Map.keys() |> MapSet.new()

    with true <- keys == @operation_keys,
         true <- is_binary(operation["path"]) and operation["path"] != "",
         true <- operation["kind"] in @kinds,
         true <- valid_severity?(operation["kind"], operation["conflict_severity"]),
         true <- is_binary(operation["proposed_sha256"]),
         true <-
           is_nil(operation["existing_sha256"]) or is_binary(operation["existing_sha256"]) do
      true
    else
      _invalid -> false
    end
  end

  defp valid_operation?(_operation), do: false

  defp valid_severity?("conflict", severity), do: severity in @severities
  defp valid_severity?(_kind, severity), do: is_nil(severity)

  defp derive_summary_flags(changeset) do
    case get_field(changeset, :operations) do
      operations when is_list(operations) ->
        changeset
        |> put_change(
          :safety_blocked,
          Enum.any?(operations, &(&1["conflict_severity"] == "safety"))
        )
        |> put_change(
          :has_ordinary_conflicts,
          Enum.any?(operations, &(&1["conflict_severity"] in ["ordinary", "drifted"]))
        )

      _invalid ->
        changeset
    end
  end
end
