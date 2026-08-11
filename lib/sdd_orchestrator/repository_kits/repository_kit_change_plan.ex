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

  Persistence here is hosted (PostgreSQL) only. `RepositoryKitPackage` (Task
  1) is a global catalog and never needed a device-authoritative store; this
  entity is project-scoped, so it should eventually follow the same
  `Device`/`Hosted` dual-authority split `RepositoryAssessments.ProfileStore`
  uses. Building that split (new `Devices.DeviceStore` callbacks, a `Local`
  adapter implementation, and the release-gated native adapter) is
  independent, cross-cutting infrastructure work that a later task in this
  slice explicitly owns ("Hosted and device storage parity"). Until then,
  `RepositoryKits.plan_change/4` refuses a device authority at the
  persistence step with `{:error, :unsupported_authority}` rather than
  silently writing device-authoritative content into hosted PostgreSQL.

  `plan_type` distinguishes an initial `"install"` plan (Task 2, compared
  against the live repository tree) from an `"update"` plan (Task 5,
  compared against the currently-installed kit's own recorded file ownership
  as well as the live repository tree — see
  `SddOrchestrator.RepositoryKits.WorkerKitUpdateComparison`). An update
  introduces the `"drifted"` conflict severity: a kit-owned file whose live
  content no longer matches what was recorded at install or last update.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  @kinds ~w(create omit conflict)
  @severities ~w(ordinary safety drifted)
  @plan_types ~w(install update)
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
    :plan_type
  ]

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
  Create-only changeset for one worker-local change plan.

  `safety_blocked` and `has_ordinary_conflicts` are always derived here from
  `operations`, never trusted from caller-supplied attrs, so the two summary
  flags can never disagree with the operations they summarize.
  """
  @spec create_changeset(map()) :: Ecto.Changeset.t()
  def create_changeset(attrs) do
    %__MODULE__{}
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
    |> check_constraint(:profile_version,
      name: :repository_kit_change_plans_profile_version_positive
    )
    |> check_constraint(:base_commit, name: :repository_kit_change_plans_commit_shape)
    |> check_constraint(:package_digest, name: :repository_kit_change_plans_digest_shape)
    |> check_constraint(:plan_type, name: :repository_kit_change_plans_plan_type_shape)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:package_id)
  end

  defp validate_operations(:operations, operations) when is_list(operations) do
    if operations != [] and Enum.all?(operations, &valid_operation?/1) do
      []
    else
      [operations: "must be a non-empty list of valid create, omit, or conflict operations"]
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
