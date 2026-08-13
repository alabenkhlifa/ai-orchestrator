defmodule SddOrchestrator.RepositoryKits.RepositoryKitInstallation do
  @moduledoc """
  One project-scoped record of one successful isolated-branch SDD kit
  application.

  An installation is created only after `RepositoryKits.apply_plan/4`
  successfully applies an owner-confirmed `RepositoryKitChangePlan` through
  `WorkerKitApply` — it records the exact package, plan, branch, resulting
  commit, per-file installed digests, and non-identifying apply evidence.

  Persistence follows the same `Device`/`Hosted` dual-authority split
  `RepositoryKitChangePlan` uses, through
  `RepositoryKits.InstallationStore` (Task 8). Unlike the change plan, this
  entity is mutable, so the device store keys it by `project_id` alone (one
  row per project) rather than by `{project_id, id}`: a fresh install and a
  later update or removal both overwrite that single key in place, exactly
  as `Devices.put_repository_pilot_selection/2` already does for its own
  single-key-per-project value. `to_value/1` and `from_value/1` serialize
  this schema's exact current-state value for the device adapter, mirroring
  `RepositoryKitChangePlan`'s own pair but covering two timestamps
  (`inserted_at` and `updated_at`) instead of one, since this schema's
  `timestamps()` are not `updated_at: false`.

  Unlike `RepositoryKitPackage` and `RepositoryKitChangePlan`, this schema is
  not immutable: it carries a `state` that transitions through `"applied"`
  (Task 4, the initial install), `"updated"` (Task 5), and `"removed"`
  (Task 6). There is exactly one current installation row per project —
  `project_id` is uniquely indexed — and `update_changeset/2` overwrites
  every "current state" field in place while appending a snapshot of the
  pre-transition state to `history`, so the row's identity is stable across
  an update or a removal rather than replaced by a new row. A `"removed"`
  installation always carries an empty `installed_files` list — a removal
  plan never contains a `"create"` operation, so nothing remains to record
  as currently installed. The database allows `UPDATE` (no immutability
  trigger), unlike the append-only schemas above, exactly so
  `update_changeset/2` can be applied.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @states ~w(applied updated removed)
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

  @update_fields [
    :package_id,
    :package_digest,
    :plan_id,
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
    :confirmed_at,
    :history
  ]

  @update_required_fields [
    :package_id,
    :package_digest,
    :plan_id,
    :profile_version,
    :base_commit,
    :root,
    :repository_provider,
    :repository_id,
    :branch,
    :result_commit,
    :confirmed_by_actor_ref,
    :confirmed_at,
    :history
  ]

  # The complete struct shape for device-value serialization: every `@fields`
  # entry (the create-only cast list) plus `:history` (cast only by the
  # update changeset) plus `:inserted_at` and `:updated_at` (never cast by
  # either changeset — both come from Ecto's own `timestamps()` on the hosted
  # path). A stored device value must round-trip a freshly-created or a
  # since-transitioned installation identically, so `to_value/1` always
  # captures whichever state the installation actually holds, not just what
  # one changeset's field list happens to touch.
  @value_fields @fields ++ [:history, :inserted_at, :updated_at]
  @value_keys MapSet.new(Enum.map(@value_fields, &Atom.to_string/1))

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
    field :history, {:array, :map}, default: []

    timestamps()
  end

  @doc """
  Create-only changeset for one successful isolated-branch kit application.

  `state` always defaults to `"applied"` here — the only state this task
  produces; `update_changeset/2` transitions it further. Layers
  database-only constraints onto the shared pure-validation changeset.
  """
  @spec create_changeset(map()) :: Ecto.Changeset.t()
  def create_changeset(attrs) do
    %__MODULE__{}
    |> changeset(attrs, @fields, @required_fields)
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

  @doc """
  Update changeset transitioning an existing installation to reflect a newly
  applied `"update"` or `"removal"` plan.

  Overwrites every "current state" field with the transition's new values,
  and separately accepts a `history` list — the caller (`RepositoryKits`)
  computes that list as a snapshot of the pre-transition state prepended to
  the existing `installation.history`; this changeset only casts, validates,
  and persists whatever `history` it is given. `state` is expected to be
  `"updated"` or `"removed"` here, but any value in `@states` validates,
  exactly mirroring `create_changeset/1`'s own discipline. Layers
  database-only constraints onto the shared pure-validation changeset.
  """
  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(%__MODULE__{} = installation, attrs) do
    installation
    |> changeset(attrs, @update_fields, @update_required_fields)
    |> check_constraint(:profile_version,
      name: :repository_kit_installations_profile_version_positive
    )
    |> check_constraint(:base_commit, name: :repository_kit_installations_base_commit_shape)
    |> check_constraint(:result_commit, name: :repository_kit_installations_result_commit_shape)
    |> check_constraint(:package_digest, name: :repository_kit_installations_digest_shape)
    |> foreign_key_constraint(:package_id)
    |> foreign_key_constraint(:plan_id)
  end

  @doc """
  Builds one in-memory, pure-validated installation without any database
  constraint.

  Casts the complete `@value_fields` shape (unlike either changeset above,
  which each cast only their own narrower field list) but requires only the
  same always-required scalars `@required_fields` already names — `:history`,
  `:installed_files`, and `:evidence` stay optional here exactly as they are
  on create, since all three carry schema defaults. Used both by
  `from_value/1` (restoring a device-authoritative stored value) and by the
  device installation-store adapter (validating a value before it is ever
  written to device storage).
  """
  @spec build(map()) :: {:ok, t()} | {:error, :invalid_installation}
  def build(attrs) do
    %__MODULE__{}
    |> changeset(attrs, @value_fields, @required_fields)
    |> apply_action(:insert)
    |> case do
      {:ok, installation} -> {:ok, installation}
      {:error, _changeset} -> {:error, :invalid_installation}
    end
  end

  @doc "Serializes the exact device-authoritative value without Ecto metadata."
  @spec to_value(t()) :: map()
  def to_value(%__MODULE__{} = installation) do
    installation
    |> Map.take(@value_fields)
    |> Map.new(fn
      {key, %DateTime{} = value} -> {Atom.to_string(key), DateTime.to_iso8601(value)}
      {key, value} -> {Atom.to_string(key), value}
    end)
  end

  @doc "Restores only the exact device-authoritative value, in whatever state it holds."
  @spec from_value(term()) :: {:ok, t()} | {:error, :invalid_installation}
  def from_value(value) when is_map(value) do
    with true <- MapSet.new(Map.keys(value)) == @value_keys,
         {:ok, confirmed_at, 0} <- DateTime.from_iso8601(value["confirmed_at"]),
         {:ok, inserted_at, 0} <- DateTime.from_iso8601(value["inserted_at"]),
         {:ok, updated_at, 0} <- DateTime.from_iso8601(value["updated_at"]) do
      value
      |> Map.new(fn {key, field_value} -> {String.to_existing_atom(key), field_value} end)
      |> Map.merge(%{
        confirmed_at: confirmed_at,
        inserted_at: inserted_at,
        updated_at: updated_at
      })
      |> build()
    else
      _invalid -> {:error, :invalid_installation}
    end
  rescue
    _error -> {:error, :invalid_installation}
  end

  def from_value(_value), do: {:error, :invalid_installation}

  # The shared pure-validation core both changesets, and `build/1`, run —
  # only the cast/required field lists and the database-only constraints
  # layered on afterward differ between callers.
  defp changeset(installation, attrs, fields, required_fields) do
    installation
    |> cast(attrs, fields)
    |> validate_required(required_fields)
    |> validate_length(:root, max: 4096, count: :bytes)
    |> validate_length(:repository_provider, max: 255, count: :bytes)
    |> validate_length(:repository_id, max: 255, count: :bytes)
    |> validate_length(:branch, max: 255, count: :bytes)
    |> validate_number(:profile_version, greater_than: 0)
    |> validate_format(:base_commit, @commit_format)
    |> validate_format(:result_commit, @commit_format)
    |> validate_format(:package_digest, @digest_format)
    |> validate_inclusion(:state, @states)
  end
end
